import Queues
import QueuesRedisDriver
import Vapor

public enum AppRuntimeMode: String, Sendable {
    case api
    case worker
}

public func configure(_ app: Application, mode: AppRuntimeMode) async throws {
    try configureQueues(on: app)

    app.nwsIngestService = StubNWSIngestService()
    app.queues.add(IngestNWSAlertsJob())

    switch mode {
    case .api:
        try configureAPIRoutes(app)
    case .worker:
        configureWorkerQueueSettings(on: app)
        configureWorkerRuntime(on: app)
        app.queues.schedule(DispatchIngestNWSAlertsScheduledJob()).minutely().at(0)
        app.logger.info("Configured scheduled ingestion dispatch (every 60 seconds).")
        try configureWorkerRoutes(app)
    }
}

private func configureQueues(on app: Application) throws {
    guard let redisURL = Environment.get("REDIS_URL"), !redisURL.isEmpty else {
        if app.environment == .development || app.environment == .testing {
            let defaultRedisURL = "redis://127.0.0.1:6379"
            app.logger.warning(
                "REDIS_URL is not set; defaulting to \(defaultRedisURL) for \(app.environment.name)."
            )
            try useRedisQueues(on: app, url: defaultRedisURL)
            return
        }

        throw Abort(
            .internalServerError,
            reason: "REDIS_URL must be set when running in \(app.environment.name)."
        )
    }

    try useRedisQueues(on: app, url: redisURL)
}

private func useRedisQueues(on app: Application, url: String) throws {
    let maxConnections = max(2, Environment.get("REDIS_POOL_MAX_CONNECTIONS").flatMap(Int.init) ?? 8)
    let connectionTimeoutSeconds = max(1, Environment.get("REDIS_POOL_CONNECTION_TIMEOUT_SECONDS").flatMap(Int.init) ?? 30)
    let poolOptions = RedisConfiguration.PoolOptions(
        maximumConnectionCount: .maximumActiveConnections(maxConnections),
        minimumConnectionCount: 1,
        connectionRetryTimeout: .seconds(Int64(connectionTimeoutSeconds))
    )
    let configuration = try RedisConfiguration(url: url, pool: poolOptions)
    app.queues.use(.redis(configuration))
}

private func configureWorkerQueueSettings(on app: Application) {
    let workerCount = max(1, Environment.get("QUEUE_WORKER_COUNT").flatMap(Int.init) ?? 1)
    app.queues.configuration.workerCount = .custom(workerCount)
    app.logger.info(
        "Worker queue settings configured.",
        metadata: [
            "workerCount": .stringConvertible(workerCount),
            "redisPoolMaxConnections": .string(Environment.get("REDIS_POOL_MAX_CONNECTIONS") ?? "8"),
            "redisPoolConnectionTimeoutSeconds": .string(Environment.get("REDIS_POOL_CONNECTION_TIMEOUT_SECONDS") ?? "30")
        ]
    )
}

private func configureWorkerRuntime(on app: Application) {
    let startupGraceSeconds = max(0, Environment.get("WORKER_STARTUP_GRACE_SECONDS").flatMap(Int.init) ?? 5)
    app.logger.info(
        "Worker runtime settings configured.",
        metadata: ["startupGraceSeconds": .stringConvertible(startupGraceSeconds)]
    )

    guard app.environment != .testing else {
        return
    }

    app.lifecycle.use(WorkerRuntime(startupGracePeriodSeconds: Int64(startupGraceSeconds)))
}

private func configureAPIRoutes(_ app: Application) throws {
    app.get("health") { _ in
        "ok"
    }
}

private func configureWorkerRoutes(_ app: Application) throws {
    app.get("health") { _ in
        "ok"
    }
}
