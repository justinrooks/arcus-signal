import Foundation
import Queues
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// One worker-owned cursor per root; each pass examines at most 500 entries.
/// A restart begins a new sweep. No request performs tree traversal.
actor SurfaceCacheCleanupService {
    struct Report: Sendable {
        var examined = 0
        var removedFiles = 0
        var removedBytes: Int64 = 0
        var completedSweep = false
    }

    private let scanner = Scanner()

    func cleanup(rootURL: URL, snapshots: Bool, now: Date,
                 executor: any PressureArtifactBlockingWorkExecuting,
                 limit: Int = 500, grace: TimeInterval = 600) async throws -> Report {
        let scanner = scanner
        return try await executor.execute {
            try scanner.pass(rootURL: rootURL, snapshots: snapshots, now: now, limit: limit, grace: grace)
        }
    }

    // Executor ownership is serialized even if actor reentrancy overlaps two passes.
    private final class Scanner: @unchecked Sendable {
        private let section = BlockingWorkCriticalSection()
        private var cursors: [URL: FileManager.DirectoryEnumerator] = [:]

        func pass(rootURL: URL, snapshots: Bool, now: Date, limit: Int, grace: TimeInterval) throws -> Report {
            try section.withLock {
                guard (try? rootURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return Report() }
                let root = rootURL.standardizedFileURL.resolvingSymlinksInPath()
                guard FileManager.default.fileExists(atPath: root.path),
                      let gate = try SurfaceCacheFileLease.attempt(rootURL: root, identity: "", kind: .operation) else {
                    return Report()
                }
                defer { withExtendedLifetime(gate) {} }
                if cursors[root] == nil {
                    cursors[root] = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
                }
                guard let cursor = cursors[root] else { return Report() }
                var report = Report()
                for _ in 0..<max(0, limit) {
                    guard let url = cursor.nextObject() as? URL else {
                        cursors[root] = nil
                        report.completedSweep = true
                        break
                    }
                    report.examined += 1
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        cursor.skipDescendants()
                        continue
                    }
                    guard url.lastPathComponent == (snapshots ? "snapshot.json" : "subset.json") else { continue }
                    let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
                    let prefix = root.path + "/"
                    guard normalizedURL.path.hasPrefix(prefix) else { continue }
                    let relative = String(normalizedURL.deletingLastPathComponent().path.dropFirst(prefix.count))
                    let components = relative.split(separator: "/").map(String.init)
                    guard components.count == (snapshots ? 9 : 8) else { continue }
                    // Recheck metadata and unlink while publication is excluded. Busy
                    // GRIB readers skip this entry until a later complete sweep.
                    do {
                        let removal = snapshots ? nil : try SurfaceCacheFileLease.attempt(
                            rootURL: root, identity: relative, kind: .removal
                        )
                        if !snapshots && removal == nil { continue }
                        defer { withExtendedLifetime(removal) {} }
                        let directory = try SurfaceCacheFileLease.openDirectory(rootURL: root, components: components)
                        defer { close(directory) }
                        let name = url.lastPathComponent
                        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                        guard fd >= 0 else { continue }
                        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        defer { try? handle.close() }
                        var info = stat()
                        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                              info.st_size > 0, info.st_size <= 1_048_576 else { continue }
                        let data = try handle.read(upToCount: 1_048_577) ?? Data()
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        let expiry: Date
                        if snapshots {
                            let record = try decoder.decode(StormSetupSnapshotCacheRecord.self, from: data)
                            guard record.key.cacheIdentifier == relative else { continue }
                            expiry = record.snapshot.freshness.expiresAt
                        } else {
                            let record = try decoder.decode(GribSubsetCacheRecord.self, from: data)
                            guard try StormSetupCacheKey(sourceMetadata: record.source).cacheIdentifier == relative else { continue }
                            expiry = record.expiresAt
                        }
                        guard expiry <= now.addingTimeInterval(-max(0, grace)) else { continue }
                        #if canImport(Darwin)
                        let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                        #else
                        let modified = Date(timeIntervalSince1970: Double(info.st_mtim.tv_sec))
                        #endif
                        guard modified <= now.addingTimeInterval(-max(0, grace)) else { continue }
                        if !snapshots {
                            var bodyInfo = stat()
                            guard fstatat(directory, "subset.grib2", &bodyInfo, AT_SYMLINK_NOFOLLOW) == 0,
                                  bodyInfo.st_mode & S_IFMT == S_IFREG else { continue }
                        }
                        let names = snapshots ? [name] : ["subset.grib2", name]
                        for item in names {
                            var itemInfo = stat()
                            guard fstatat(directory, item, &itemInfo, AT_SYMLINK_NOFOLLOW) == 0,
                                  itemInfo.st_mode & S_IFMT == S_IFREG else { continue }
                            if unlinkat(directory, item, 0) == 0 {
                                report.removedFiles += 1
                                report.removedBytes += Int64(itemInfo.st_size)
                            }
                        }
                        // Reclaim empty identity directories too; lock inodes live
                        // only in the root and must survive every sweep.
                        for depth in stride(from: components.count, through: 1, by: -1) {
                            let parent = try SurfaceCacheFileLease.openDirectory(rootURL: root, components: Array(components.prefix(depth - 1)))
                            let result = unlinkat(parent, components[depth - 1], AT_REMOVEDIR)
                            close(parent)
                            if result != 0 { break }
                        }
                    } catch {
                        // Unknown, malformed, unreadable or unsafe entries are retained.
                        continue
                    }
                }
                return report
            }
        }
    }
}

struct CleanupSurfaceCachesScheduledJob: AsyncScheduledJob {
    let service = SurfaceCacheCleanupService()

    func run(context: QueueContext) async throws {
        let app = context.application
        let executor = NIOThreadPoolPressureArtifactBlockingWorkExecutor(threadPool: app.threadPool)
        let configuration = app.stormSetupConfiguration
        for (root, snapshots) in [(configuration.gribSubsetCacheRootURL, false),
                                  (configuration.sampledSnapshotCacheRootURL, true)] {
            let start = ContinuousClock.now
            let report = try await service.cleanup(rootURL: root, snapshots: snapshots, now: Date(), executor: executor)
            context.logger.info("Surface cache cleanup pass completed.", metadata: [
                "snapshots": .stringConvertible(snapshots), "examined": .stringConvertible(report.examined),
                "removedFiles": .stringConvertible(report.removedFiles), "removedBytes": .stringConvertible(report.removedBytes),
                "elapsed": .stringConvertible(start.duration(to: .now))
            ])
        }
    }
}
