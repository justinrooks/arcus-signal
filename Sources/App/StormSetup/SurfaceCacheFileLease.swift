import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Fixed lock inodes are never removed. All participants must use this protocol;
/// rolling back to a nonparticipating binary requires stopping cleanup first.
final class SurfaceCacheFileLease: Sendable {
    enum Kind: Sendable { case operation, reader, removal }
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }
    deinit { close(descriptor) }

    static func acquire(
        rootURL: URL, identity: String, kind: Kind,
        executor: any PressureArtifactBlockingWorkExecuting
    ) async throws -> SurfaceCacheFileLease {
        while true {
            try Task.checkCancellation()
            if let lease = try await executor.execute({
                try attempt(rootURL: rootURL, identity: identity, kind: kind)
            }) { return lease }
            // Never park a bounded filesystem thread waiting for a reader/process.
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    static func attempt(rootURL: URL, identity: String, kind: Kind) throws -> SurfaceCacheFileLease? {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        guard (try rootURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw POSIXError(.ELOOP)
        }
        let root = rootURL.resolvingSymlinksInPath()
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { throw POSIXError(.EIO) }
        defer { close(rootFD) }
        // Stable FNV-1a, independent of Swift's randomized Hasher/process seed.
        let hash = identity.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let name = kind == .operation ? ".surface-operation.lock" : ".surface-reader-\(hash % 64).lock"
        let fd = openat(rootFD, name, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw POSIXError(.EINVAL)
        }
        let mode = kind == .reader ? LOCK_SH : LOCK_EX
        guard flock(fd, mode | LOCK_NB) == 0 else {
            let failure = errno
            close(fd)
            if failure == EWOULDBLOCK || failure == EAGAIN { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        return SurfaceCacheFileLease(descriptor: fd)
    }

    /// Walk relative to an anchored root, refusing symlinks at every level.
    static func openDirectory(rootURL: URL, components: [String]) throws -> Int32 {
        var fd = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in components {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                close(fd)
                throw POSIXError(.EINVAL)
            }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { throw POSIXError(.EIO) }
            fd = next
        }
        return fd
    }
}
