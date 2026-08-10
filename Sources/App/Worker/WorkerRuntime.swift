import Queues
import Redis
import Vapor

public final class WorkerRuntime: LifecycleHandler, @unchecked Sendable {
    typealias RecoveryOperation = @Sendable (Application) async throws -> ModelArtifactQueueRecoverySummary
    typealias QueueConsumerStarter = @Sendable (Application, ArcusQueueLane) throws -> Void
    typealias ScheduledJobStarter = @Sendable (Application) throws -> Void

    private let startupGracePeriodSeconds: Int64
    private let recoveryOperation: RecoveryOperation
    private let queueConsumerStarter: QueueConsumerStarter
    private let scheduledJobStarter: ScheduledJobStarter
    private var startupTask: Task<Void, Never>?

    public init(startupGracePeriodSeconds: Int64 = 5) {
        self.startupGracePeriodSeconds = max(0, startupGracePeriodSeconds)
        self.recoveryOperation = { app in
            let queue = app.queues.queue(ArcusQueueLane.modelArtifacts.queueName)
            guard let redis = queue as? any RedisClient else {
                throw ModelArtifactQueueRecoveryError.redisQueueDriverUnavailable
            }
            return try await ModelArtifactQueueRecoveryStore(queue: queue, redis: redis)
                .recoverKnownJobs()
        }
        self.queueConsumerStarter = { app, lane in
            try app.queues.startInProcessJobs(on: lane.queueName)
        }
        self.scheduledJobStarter = { app in
            try app.queues.startScheduledJobs()
        }
    }

    init(
        startupGracePeriodSeconds: Int64 = 0,
        recoveryOperation: @escaping RecoveryOperation,
        queueConsumerStarter: @escaping QueueConsumerStarter,
        scheduledJobStarter: @escaping ScheduledJobStarter
    ) {
        self.startupGracePeriodSeconds = max(0, startupGracePeriodSeconds)
        self.recoveryOperation = recoveryOperation
        self.queueConsumerStarter = queueConsumerStarter
        self.scheduledJobStarter = scheduledJobStarter
    }

    public func didBoot(_ app: Application) throws {
        logQueueBackend(on: app)
        guard startupGracePeriodSeconds == 0 else {
            scheduleDelayedStart(on: app)
            return
        }

        try app.eventLoopGroup.any().makeFutureWithTask {
            try await self.startWorkerRuntime(on: app)
        }.wait()
    }

    public func didBootAsync(_ app: Application) async throws {
        logQueueBackend(on: app)
        guard startupGracePeriodSeconds == 0 else {
            scheduleDelayedStart(on: app)
            return
        }

        try await startWorkerRuntime(on: app)
    }

    public func shutdown(_ app: Application) {
        startupTask?.cancel()
        app.logger.info("Worker runtime stopped.")
    }

    private func logQueueBackend(on app: Application) {
        if let redisURL = Environment.get("REDIS_URL"), let parsed = URL(string: redisURL) {
            let port = parsed.port ?? 6379
            app.logger.info("Worker queue backend: redis://\(parsed.host ?? "unknown"):\(port)")
        } else {
            app.logger.info("Worker queue backend: redis://127.0.0.1:6379 (default)")
        }
    }

    private func scheduleDelayedStart(on app: Application) {
        startupTask = Task { [startupGracePeriodSeconds] in
            do {
                try await Task.sleep(for: .seconds(startupGracePeriodSeconds))
            } catch {
                return
            }

            do {
                try await startWorkerRuntime(on: app)
            } catch {
                app.logger.error(
                    "Failed to start worker runtime.",
                    metadata: [
                        "errorType": .string(String(describing: type(of: error))),
                        "error": .string(String(reflecting: error))
                    ]
                )
                app.logger.critical("Shutting down worker process after runtime startup failure.")
                try? await app.asyncShutdown()
            }
        }
    }

    func reconcileAndStartQueueRuntime(on app: Application) async throws {
        let recoverySummary = try await recoveryOperation(app)
        app.logger.info(
            "Model-artifact queue recovery completed.",
            metadata: [
                "inspectedEntries": .stringConvertible(recoverySummary.inspectedEntryCount),
                "returnedToWaiting": .stringConvertible(recoverySummary.returnedJobIdentifiers.count),
                "alreadyWaiting": .stringConvertible(recoverySummary.alreadyWaitingJobIdentifiers.count),
                "removedProcessingEntries": .stringConvertible(recoverySummary.removedProcessingEntryCount),
                "preservedMissingJobData": .stringConvertible(recoverySummary.preservedMissingJobDataCount),
                "preservedMalformedJobData": .stringConvertible(recoverySummary.preservedMalformedJobDataCount),
                "preservedMalformedIdentifiers": .stringConvertible(recoverySummary.preservedMalformedIdentifierCount),
                "preservedUnknownJobs": .stringConvertible(recoverySummary.preservedUnknownJobCount),
                "returnedJobIdentifiers": .string(recoverySummary.returnedJobIdentifiers.joined(separator: ",")),
                "alreadyWaitingJobIdentifiers": .string(recoverySummary.alreadyWaitingJobIdentifiers.joined(separator: ","))
            ]
        )

        for lane in ArcusQueueLane.allCases {
            try queueConsumerStarter(app, lane)
            app.logger.info(
                "Worker queue consumers started.",
                metadata: ["lane": .string(lane.rawValue)]
            )
        }
        try scheduledJobStarter(app)
        app.logger.info("Worker scheduled jobs started.")
    }

    private func startWorkerRuntime(on app: Application) async throws {
        try await reconcileAndStartQueueRuntime(on: app)

        Task {
            do {
                try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true)
            } catch {
                app.logger.error(
                    "Failed to bootstrap operator dashboard snapshot.",
                    metadata: ["error": .string(String(reflecting: error))]
                )
            }
        }
    }
}
