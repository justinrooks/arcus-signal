@testable import App
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
