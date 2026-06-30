@testable import App
import Foundation
import NIOPosix
import Vapor

func makePressureArtifactBlockingWorkExecutor(
    application: Application
) -> NIOThreadPoolPressureArtifactBlockingWorkExecutor {
    NIOThreadPoolPressureArtifactBlockingWorkExecutor(threadPool: application.threadPool)
}

func withPressureArtifactThreadPoolExecutor<T>(
    _ operation: (NIOThreadPoolPressureArtifactBlockingWorkExecutor) async throws -> T
) async throws -> T {
    let threadPool = NIOThreadPool(numberOfThreads: 1)
    threadPool.start()
    do {
        let result = try await operation(
            NIOThreadPoolPressureArtifactBlockingWorkExecutor(threadPool: threadPool)
        )
        try await threadPool.shutdownGracefully()
        return result
    } catch {
        try? await threadPool.shutdownGracefully()
        throw error
    }
}

final class CountingPressureArtifactBlockingWorkExecutor: PressureArtifactBlockingWorkExecuting, @unchecked Sendable {
    private let wrapped: any PressureArtifactBlockingWorkExecuting
    private let counter = ExecutionCounter()

    init(wrapping wrapped: any PressureArtifactBlockingWorkExecuting) {
        self.wrapped = wrapped
    }

    func executionCount() async -> Int {
        await counter.value
    }

    func execute<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        await counter.increment()
        return try await wrapped.execute(operation)
    }
}

private actor ExecutionCounter {
    var value = 0

    func increment() {
        value += 1
    }
}
