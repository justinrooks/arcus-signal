import Queues
import Vapor

public struct DispatchIngestSPCMesoScheduledJob: AsyncScheduledJob {
    public init() {}

    public func run(context: QueueContext) async throws {
        context.logger.info("Scheduler dispatching IngestSPCMesoJob.")
        try await context.application.queues
            .queue(ArcusQueueLane.ingest.queueName)
            .dispatch(IngestSPCMesoJob.self, .init())
    }
}

@discardableResult
func registerSPCMesoIngestSchedule(on application: Application) -> ScheduleBuilder {
    let schedule = application.queues.schedule(DispatchIngestSPCMesoScheduledJob())
    schedule.every(seconds: 600)
    application.recordWorkerScheduledJob("DispatchIngestSPCMesoScheduledJob")
    return schedule
}
