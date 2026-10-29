@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("Surface cache cleanup", .serialized)
struct SurfaceCacheCleanupTests {
    private func source(_ time: Date) -> StormSetupSourceMetadata {
        HrrrNomadsURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(runTime: time, forecastHour: 0),
            around: StormSetupCentroid(latitude: 39.7, longitude: -104.4)
        )
    }

    @Test("hourly churn converges and bounded passes survive restart", arguments: [false, true])
    func hourlyChurn(snapshots: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = PressureArtifactBlockingWorkTestContext()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        var baselineBytes = 0
        var removedBytes: Int64 = 0
        var removedFiles = 0
        var service = SurfaceCacheCleanupService()
        let clock = ContinuousClock()
        let start = clock.now
        var passes = 0
        var cleanupTime = Duration.zero
        var maximumPassTime = Duration.zero
        var examined = 0
        for hour in 0..<72 {
            let time = base.addingTimeInterval(Double(hour) * 3600)
            let metadata = source(time)
            let key = try StormSetupCacheKey(sourceMetadata: metadata)
            let expiry = time.addingTimeInterval(12 * 3600)
            let data: Data
            let file: URL
            if snapshots {
                let snapshotKey = try StormSetupSnapshotCacheKey(h3Cell: 1, sourceMetadata: metadata, rulesVersion: .current)
                let freshness = IngredientFreshness(sourceValidTime: metadata.validTime, modelRunTime: metadata.runTime, forecastHour: 0, fetchedAt: time, expiresAt: expiry, isStale: false, isDegraded: false)
                let snapshot = TornadoIngredientSnapshot(h3Cell: 1, centroid: StormSetupCentroid(latitude: 39.7, longitude: -104.4), source: metadata, raw: .empty, assessment: TornadoIngredientInterpreter().assess(raw: .empty, freshness: freshness), freshness: freshness)
                file = snapshotKey.snapshotFileURL(rootURL: root)
                data = try encoder.encode(StormSetupSnapshotCacheRecord(key: snapshotKey, snapshot: snapshot))
                try FileManager.default.createDirectory(at: snapshotKey.directoryURL(rootURL: root), withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: key.directoryURL(rootURL: root), withIntermediateDirectories: true)
                let record = GribSubsetCacheRecord(source: metadata, byteSize: 32, checksumSHA256: "fixture", fetchedAt: time, expiresAt: expiry)
                file = key.metadataFileURL(rootURL: root)
                data = try encoder.encode(record)
                try Data(repeating: 1, count: 32).write(to: key.subsetFileURL(rootURL: root))
            }
            try data.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: file.path)
            baselineBytes += data.count + (snapshots ? 0 : 32)
            if hour == 36 {
                let interrupted = try await service.cleanup(rootURL: root, snapshots: snapshots, now: time, executor: work.executor, limit: 1, grace: 3600)
                #expect(!interrupted.completedSweep)
                service = SurfaceCacheCleanupService()
            }
            // Drain this small fixture; each scheduled pass retains its own cursor.
            for _ in 0..<200 {
                let passStart = clock.now
                let report = try await service.cleanup(rootURL: root, snapshots: snapshots, now: time, executor: work.executor, limit: 17, grace: 3600)
                let elapsed = passStart.duration(to: clock.now)
                cleanupTime += elapsed
                maximumPassTime = max(maximumPassTime, elapsed)
                examined += report.examined
                #expect(report.examined <= 17)
                passes += 1
                removedFiles += report.removedFiles
                removedBytes += report.removedBytes
                if report.completedSweep { break }
            }
        }
        let urls = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        let retained = urls.filter { ["subset.json", "subset.grib2", "snapshot.json"].contains($0.lastPathComponent) }
        let retainedBytes = try retained.reduce(Int64(0)) { try $0 + Int64(Data(contentsOf: $1).count) }
        #expect(retained.count == (snapshots ? 13 : 26)) // 12-hour retention + one-hour conservative grace.
        #expect(removedFiles == (snapshots ? 59 : 118))
        #expect(removedBytes + retainedBytes == baselineBytes)
        print("surface fixture snapshots=\(snapshots) baselineFiles=\(snapshots ? 72 : 144) baselineBytes=\(baselineBytes) retainedFiles=\(retained.count) retainedBytes=\(retainedBytes) passes=\(passes) examined=\(examined) cleanupElapsed=\(cleanupTime) meanPass=\(cleanupTime / passes) maxPass=\(maximumPassTime) fixtureElapsed=\(start.duration(to: clock.now))")
    }

    @Test("interrupted body publication is reclaimed after restart without an old-key lookup")
    func interruptedPublicationOrphan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = PressureArtifactBlockingWorkTestContext()
        let time = Date(timeIntervalSince1970: 1_780_000_000)
        let key = try StormSetupCacheKey(sourceMetadata: source(time))
        let body = key.subsetFileURL(rootURL: root)
        try FileManager.default.createDirectory(at: key.directoryURL(rootURL: root), withIntermediateDirectories: true)
        let payload = Data([71, 82, 73, 66, 0, 0, 0, 2] + Array(repeating: 0, count: 8) + [55, 55, 55, 55])
        // Execute the crash boundary in another process: atomic body replacement,
        // then immediate exit without publishing metadata or running cleanup.
        let process = Process()
        let exited = SurfaceTestBarrier()
        process.terminationHandler = { _ in Task { await exited.release() } }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,os,pathlib,sys\nf=open(sys.argv[1],'a+')\nfcntl.flock(f,fcntl.LOCK_EX)\np=pathlib.Path(sys.argv[2])\nt=p.with_suffix('.tmp')\nt.write_bytes(bytes.fromhex(sys.argv[3]))\nos.replace(t,p)\nos._exit(0)", root.appendingPathComponent(".surface-operation.lock").path, body.path, payload.map { String(format: "%02x", $0) }.joined()]
        try process.run()
        await exited.pause()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: key.metadataFileURL(rootURL: root).path))
        try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: body.path)
        let retention: TimeInterval = 12 * 3600
        let cutoff = time.addingTimeInterval(retention + 600)
        var service = SurfaceCacheCleanupService()
        let partial = try await service.cleanup(rootURL: root, snapshots: false, now: cutoff, executor: work.executor, limit: 1)
        #expect(!partial.completedSweep)
        service = SurfaceCacheCleanupService() // Restart discards the unfinished cursor.
        let young = try await service.cleanup(rootURL: root, snapshots: false, now: cutoff.addingTimeInterval(-1), executor: work.executor)
        #expect(young.removedFiles == 0)
        let reader = try ChildSurfaceLease(root: root, identity: key.cacheIdentifier)
        let pinned = try await service.cleanup(rootURL: root, snapshots: false, now: cutoff, executor: work.executor)
        #expect(pinned.removedFiles == 0)
        await reader.finish()
        let removed = try await service.cleanup(rootURL: root, snapshots: false, now: cutoff, executor: work.executor)
        #expect(removed.removedFiles == 1)
        #expect(removed.removedBytes == payload.count)
        #expect(!FileManager.default.fileExists(atPath: body.path))
        #expect(!FileManager.default.fileExists(atPath: key.directoryURL(rootURL: root).path))
    }

    @Test("orphan reclamation retains ambiguous bodies, metadata and paths")
    func orphanSafetyControls() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let work = PressureArtifactBlockingWorkTestContext()
        let time = Date(timeIntervalSince1970: 1_780_000_000)
        let payload = Data([71, 82, 73, 66, 0, 0, 0, 2] + Array(repeating: 0, count: 8) + [55, 55, 55, 55])
        try payload.write(to: outside)
        var retained: [URL] = []
        for (index, kind) in ["freshMetadata", "malformedMetadata", "symlinkMetadata", "symlinkBody", "unknownBody", "unknownPath"].enumerated() {
            let metadata = source(time.addingTimeInterval(Double(index) * 3600))
            let key = try StormSetupCacheKey(sourceMetadata: metadata)
            let directory = kind == "unknownPath" ? URL(fileURLWithPath: key.directoryURL(rootURL: root).path.replacingOccurrences(of: "fields=tornado-v1", with: "fields=unknown")) : key.directoryURL(rootURL: root)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let body = directory.appendingPathComponent("subset.grib2")
            if kind == "symlinkBody" {
                try FileManager.default.createSymbolicLink(at: body, withDestinationURL: outside)
            } else {
                try (kind == "unknownBody" ? Data("unrecognized".utf8) : payload).write(to: body)
                try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: body.path)
            }
            let sidecar = key.metadataFileURL(rootURL: root)
            if kind == "freshMetadata" {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(GribSubsetCacheRecord(source: metadata, byteSize: Int64(payload.count), checksumSHA256: "fixture", fetchedAt: time, expiresAt: time.addingTimeInterval(30 * 3600))).write(to: sidecar)
                try FileManager.default.setAttributes([.modificationDate: time], ofItemAtPath: sidecar.path)
            } else if kind == "malformedMetadata" {
                try Data("malformed".utf8).write(to: sidecar)
            } else if kind == "symlinkMetadata" {
                try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
            }
            retained.append(body)
        }
        let report = try await SurfaceCacheCleanupService().cleanup(rootURL: root, snapshots: false, now: time.addingTimeInterval(24 * 3600), executor: work.executor)
        #expect(report.removedFiles == 0)
        for body in retained { #expect(FileManager.default.fileExists(atPath: body.path)) }
        #expect(try Data(contentsOf: outside) == payload)
    }

    @Test("cross-process reader locks exclude removal and release on process exit")
    func crossProcessLocks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = try ChildSurfaceLease(root: root, identity: "")
        #expect(try SurfaceCacheFileLease.attempt(rootURL: root, identity: "", kind: .removal) == nil)
        await child.finish()
        #expect(try SurfaceCacheFileLease.attempt(rootURL: root, identity: "", kind: .removal) != nil)
    }

}

actor SurfaceTestBarrier {
    private var reached = false
    private var released = false
    private var observer: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause() async {
        reached = true
        observer?.resume()
        observer = nil
        if !released { await withCheckedContinuation { waiter = $0 } }
    }
    func waitUntilReached() async {
        if !reached { await withCheckedContinuation { observer = $0 } }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
}

actor PausingSurfaceExecutor: PressureArtifactBlockingWorkExecuting {
    let wrapped: any PressureArtifactBlockingWorkExecuting
    let barrier: SurfaceTestBarrier
    private var first = true
    init(wrapped: any PressureArtifactBlockingWorkExecuting, barrier: SurfaceTestBarrier) {
        self.wrapped = wrapped; self.barrier = barrier
    }
    func execute<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let pause = first
        first = false
        let value = try await wrapped.execute(operation)
        if pause { await barrier.pause() }
        return value
    }
}

final class ChildSurfaceLease {
    private let process = Process()
    private let input = Pipe()
    private let exited = SurfaceTestBarrier()
    init(root: URL, identity: String, operation: Bool = false) throws {
        let hash = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let file = operation ? ".surface-operation.lock" : ".surface-reader-\(hash % 64).lock"
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a+')\nfcntl.flock(f,fcntl.LOCK_SH if sys.argv[2]=='read' else fcntl.LOCK_EX)\nprint('ready',flush=True)\nsys.stdin.read()", root.appendingPathComponent(file).path, operation ? "operation" : "read"]
        let exited = exited
        process.terminationHandler = { _ in Task { await exited.release() } }
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        guard String(data: output.fileHandleForReading.availableData, encoding: .utf8) == "ready\n" else {
            throw POSIXError(.EIO)
        }
    }
    func finish() async {
        try? input.fileHandleForWriting.close()
        await exited.pause()
    }
    deinit { try? input.fileHandleForWriting.close() }
}

struct PausedSurfaceHTTPClient: HTTPClient {
    let barrier: SurfaceTestBarrier
    func get(_ url: URL, headers: [String: String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        await barrier.pause()
        return HTTPResponse(status: 200, headers: [:], data: Data("GRIB".utf8))
    }
    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { throw URLError(.unsupportedURL) }
    func post(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { throw URLError(.unsupportedURL) }
    func postWithoutRetry(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { throw URLError(.unsupportedURL) }
    func clearCache() {}
}

struct PausedSurfaceSampler: Wgrib2Sampling {
    let barrier: SurfaceTestBarrier
    func samplePoint(_ request: Wgrib2PointRequest) async throws -> [Wgrib2PointSample] {
        await barrier.pause()
        guard try Data(contentsOf: request.fileURL) == Data("GRIB".utf8) else { throw POSIXError(.EIO) }
        return []
    }
}
