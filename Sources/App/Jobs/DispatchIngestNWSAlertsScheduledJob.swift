import Queues
import Vapor

public struct DispatchIngestNWSAlertsScheduledJob: AsyncScheduledJob {
    public init() {}

    public func run(context: QueueContext) async throws {
        context.logger.info("Scheduler dispatching IngestNWSAlertsJob.")
        try await context.application.queues
            .queue(ArcusQueueLane.ingest.queueName)
            .dispatch(IngestNWSAlertsJob.self, .init())
    }
}
