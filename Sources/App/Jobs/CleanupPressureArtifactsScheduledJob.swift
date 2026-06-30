import Queues
import Vapor

public struct CleanupPressureArtifactsScheduledJob: AsyncScheduledJob {
    public init() {}

    public func run(context: QueueContext) async throws {
        context.logger.info("Scheduler dispatching pressure artifact cleanup.")
        try await context.application.queues
            .queue(ArcusQueueLane.modelArtifacts.queueName)
            .dispatch(CleanupPressureArtifactsJob.self, CleanupPressureArtifactsJobPayload())
    }
}
