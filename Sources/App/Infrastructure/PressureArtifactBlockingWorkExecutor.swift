import NIOConcurrencyHelpers
import NIOPosix

protocol PressureArtifactBlockingWorkExecuting: Sendable {
    func execute<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T
}

struct NIOThreadPoolPressureArtifactBlockingWorkExecutor: PressureArtifactBlockingWorkExecuting {
    private let threadPool: NIOThreadPool

    init(threadPool: NIOThreadPool) {
        self.threadPool = threadPool
    }

    func execute<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let result = try await threadPool.runIfActive(operation)
        try Task.checkCancellation()
        return result
    }
}

final class BlockingWorkCriticalSection: Sendable {
    private let lock = NIOLock()

    func withLock<T>(
        _ operation: @Sendable () throws -> T
    ) rethrows -> T {
        try lock.withLock(operation)
    }
}
