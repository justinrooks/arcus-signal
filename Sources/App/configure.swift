import Fluent
import FluentPostgresDriver
import Foundation
import Queues
import QueuesRedisDriver
import Vapor

public enum AppRuntimeMode: String, Sendable {
    case api
    case worker
}

public func configure(_ app: Application, mode: AppRuntimeMode) async throws {
    try configureDatabases(on: app)
    configureMigrations(on: app)
    try configureQueues(on: app)

    if app.environment == .testing {
        app.nwsIngestService = StubNWSIngestService()
    } else {
        app.nwsIngestService = DefaultNWSIngestService()
    }
    app.queues.add(IngestNWSAlertsJob())

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

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

private func configureMigrations(on app: Application) {
    app.migrations.add(CreateArcusEventModel())
    app.migrations.add(AddIsExpiredToArcusEventModel())
    app.migrations.add(AddContentHashToArcusEventModel())
}

private func configureDatabases(on app: Application) throws {
    if let databaseURL = Environment.get("DATABASE_URL"), !databaseURL.isEmpty {
        app.databases.use(try .postgres(url: databaseURL), as: .psql)
        app.logger.info("Postgres database configured from DATABASE_URL.")
        return
    }

    if app.environment == .development || app.environment == .testing {
        let hostname = Environment.get("DATABASE_HOST") ?? "127.0.0.1"
        let port = Environment.get("DATABASE_PORT").flatMap(Int.init) ?? 5432
        let username = Environment.get("DATABASE_USERNAME") ?? "arcus"
        let password = Environment.get("DATABASE_PASSWORD") ?? "arcus"
        let database = Environment.get("DATABASE_NAME") ?? "arcus_signal"
        let localDatabaseURL = try makePostgresURL(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: database,
            tlsMode: "disable"
        )

        app.databases.use(try .postgres(url: localDatabaseURL), as: .psql)

        app.logger.warning(
            "DATABASE_URL is not set; defaulting Postgres config for \(app.environment.name).",
            metadata: [
                "databaseHost": .string(hostname),
                "databasePort": .stringConvertible(port),
                "databaseName": .string(database)
            ]
        )
        return
    }

    throw Abort(
        .internalServerError,
        reason: "DATABASE_URL must be set when running in \(app.environment.name)."
    )
}

private func makePostgresURL(
    hostname: String,
    port: Int,
    username: String,
    password: String,
    database: String,
    tlsMode: String
) throws -> String {
    var components = URLComponents()
    components.scheme = "postgres"
    components.host = hostname
    components.port = port
    components.path = "/" + database
    components.user = username
    components.password = password
    components.queryItems = [URLQueryItem(name: "tlsmode", value: tlsMode)]

    guard let url = components.string else {
        throw Abort(.internalServerError, reason: "Failed to construct DATABASE_URL from environment values.")
    }

    return url
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

private func configureWorkerRoutes(_ app: Application) throws {
    app.get("health") { _ in
        "ok"
    }
}
