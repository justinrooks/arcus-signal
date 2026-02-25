import Queues
import Vapor

public final class WorkerRuntime: LifecycleHandler, @unchecked Sendable {
    private let startupGracePeriodSeconds: Int64
    private var startupTask: Task<Void, Never>?

    public init(startupGracePeriodSeconds: Int64 = 5) {
        self.startupGracePeriodSeconds = max(0, startupGracePeriodSeconds)
    }

    public func didBoot(_ app: Application) throws {
        if let redisURL = Environment.get("REDIS_URL"), let parsed = URL(string: redisURL) {
            let port = parsed.port ?? 6379
            app.logger.info("Worker queue backend: redis://\(parsed.host ?? "unknown"):\(port)")
        } else {
            app.logger.info("Worker queue backend: redis://127.0.0.1:6379 (default)")
        }

        if startupGracePeriodSeconds == 0 {
            try startWorkerRuntime(on: app)
            return
        }

        startupTask = Task { [startupGracePeriodSeconds] in
            do {
                try await Task.sleep(for: .seconds(startupGracePeriodSeconds))
            } catch {
                return
            }

            do {
                try startWorkerRuntime(on: app)
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

    public func shutdown(_ app: Application) {
        startupTask?.cancel()
        app.logger.info("Worker runtime stopped.")
    }

    private func startWorkerRuntime(on app: Application) throws {
        for lane in ArcusQueueLane.allCases {
            try app.queues.startInProcessJobs(on: lane.queueName)
            app.logger.info(
                "Worker queue consumers started.",
                metadata: ["lane": .string(lane.rawValue)]
            )
        }
        try app.queues.startScheduledJobs()
        app.logger.info("Worker scheduled jobs started.")
    }
}
