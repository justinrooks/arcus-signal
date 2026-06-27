import Queues
import Vapor

struct CleanupPressureArtifactsJobPayload: Codable, Sendable {
    init() {}
}

struct CleanupPressureArtifactsJob: AsyncJob {
    typealias Payload = CleanupPressureArtifactsJobPayload

    private let makeCleanupService: @Sendable (Application) -> any PressureArtifactCleaning

    init(
        makeCleanupService: @escaping @Sendable (Application) -> any PressureArtifactCleaning = { application in
            PressureArtifactCleanupService.makeDefault(application: application)
        }
    ) {
        self.makeCleanupService = makeCleanupService
    }

    init(cleanupService: any PressureArtifactCleaning) {
        self.init { _ in cleanupService }
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info("CleanupPressureArtifactsJob started.")
        let cleanupService = makeCleanupService(context.application)
        try await cleanupService.cleanup(on: context.application, logger: context.logger)
        context.logger.info("CleanupPressureArtifactsJob finished.")
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "CleanupPressureArtifactsJob failed.",
            metadata: [
                "error": .string(String(reflecting: error))
            ]
        )
    }
}
