import Queues
import Vapor

public struct DispatchIngestNWSAlertsScheduledJob: AsyncScheduledJob {
    public init() {}

    public func run(context: QueueContext) async throws {
        context.logger.info("Scheduler dispatching IngestNWSAlertsJob.")
        try await context.application.queues.queue.dispatch(IngestNWSAlertsJob.self, .init())
    }
}
