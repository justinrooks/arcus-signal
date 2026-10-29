import Queues

/// Revisit durable handoffs even when acquisition fails or weather is unchanged.
struct RecoverNWSOutboxScheduledJob: AsyncScheduledJob {
    static let intervalSeconds = 60
    static let batchLimit = 250

    func run(context: QueueContext) async throws {
        // A failed path must not starve the other independently durable paths.
        for path in ["target", "ugc", "h3"] {
            do {
                let result: DispatchDrainResult
                if path == "target" {
                    result = try await IngestNWSAlertsJob().dispatchPendingTargetJobs(
                        context: context, limit: Self.batchLimit
                    )
                } else {
                    result = try await DispatchAgent.dispatchPendingNotificationJobs(
                        context: context, mode: path, limit: Self.batchLimit
                    )
                }
                context.logger.info("NWS outbox recovery drain finished.", metadata: [
                    "path": .string(path),
                    "dispatched": .stringConvertible(result.dispatched),
                    "failed": .stringConvertible(result.failed)
                ])
            } catch {
                context.logger.error("NWS outbox recovery drain failed.", metadata: [
                    "path": .string(path), "error": .string(String(reflecting: error))
                ])
            }
        }
    }
}
