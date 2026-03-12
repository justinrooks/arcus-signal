import Fluent
import FluentPostgresDriver
import Foundation
import Queues
import QueuesRedisDriver
import Vapor
import APNS
import VaporAPNS
import APNSCore

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
    app.nwsReplayFixtureLoader = LocalNWSReplayFixtureLoader()
    app.queues.add(IngestNWSAlertsJob())
    app.queues.add(TargetEventRevisionJob())
    app.queues.add(NotificationSendJob())

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(decoder: decoder, for: .json)

    switch mode {
    case .api:
        try configureAPIRoutes(app)
    case .worker:
        try await configureAPNs(on: app)
        configureWorkerQueueSettings(on: app)
        configureWorkerRuntime(on: app)
        app.queues.schedule(DispatchIngestNWSAlertsScheduledJob()).minutely().at(0)
        app.logger.info("Configured scheduled ingestion dispatch (every 60 seconds).")
        try configureWorkerRoutes(app)
    }
}

private func configureMigrations(on app: Application) {
    app.migrations.add(CreatePgcryptoExtension())
    app.migrations.add(CreateAlertSeriesModel())
    app.migrations.add(CreateAlertRevision())
    app.migrations.add(AddGeometryJSONBToAlertSeries())
    app.migrations.add(EnforceContentFingerprintIntegrityOnAlertSeries())
    app.migrations.add(CreateArcusGeolocation())
    app.migrations.add(AddArcusGeolocationTimestampsIfMissing())
    app.migrations.add(CreateTargetDispatchOutbox())
    app.migrations.add(CreateNotificationOutbox())
    app.migrations.add(CreateDeviceInstallations())
    app.migrations.add(CreateDevicePresence())
    app.migrations.add(ConvertInstallationIDsToUUID())
    app.migrations.add(CreateNotificationLedger())
    app.migrations.add(AddCreatedToNotificationLedger())
    app.migrations.add(AddReasonToNotificationOutbox())
    app.migrations.add(AddRemainingArcusSeriesFields())
    app.migrations.add(FixArcusSeriesSenderNameField())
    app.migrations.add(RemoveArcusSeriesSenderNameField())
}

private func configureAPNs(on app: Application) async throws {
    let requiredKeys = ["APNS_PRIVATE_KEY_PATH", "APNS_KEY_ID", "APNS_TEAM_ID"]
    let values = requiredKeys.reduce(into: [String: String]()) { partialResult, key in
        if let rawValue = Environment.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !rawValue.isEmpty {
            partialResult[key] = rawValue
        }
    }
    let missingKeys = requiredKeys.filter { values[$0] == nil }

    guard missingKeys.isEmpty else {
        let reason = "APNS configuration is incomplete. Missing: \(missingKeys.joined(separator: ", "))."
        if app.environment == .development || app.environment == .testing {
            app.logger.warning("\(reason) APNS is disabled for \(app.environment.name).")
            return
        }
        throw Abort(.internalServerError, reason: reason)
    }

    let privateKeyPath = values["APNS_PRIVATE_KEY_PATH"]!
    let privateKeyPEM: String
    do {
        privateKeyPEM = try String(contentsOfFile: privateKeyPath, encoding: .utf8)
    } catch {
        let reason = "Failed to read APNS private key from APNS_PRIVATE_KEY_PATH."
        if app.environment == .development || app.environment == .testing {
            app.logger.warning(
                "\(reason) APNS is disabled for \(app.environment.name).",
                metadata: [
                    "apnsPrivateKeyPath": .string(privateKeyPath),
                    "error": .string(String(describing: error))
                ]
            )
            return
        }
        throw Abort(.internalServerError, reason: reason)
    }

    let authenticationMethod: APNSClientConfiguration.AuthenticationMethod
    do {
        authenticationMethod = .jwt(
            privateKey: try .loadFrom(string: privateKeyPEM),
            keyIdentifier: values["APNS_KEY_ID"]!,
            teamIdentifier: values["APNS_TEAM_ID"]!
        )
    } catch {
        let reason = "Failed to load APNS private key from APNS_PRIVATE_KEY_PATH."
        if app.environment == .development || app.environment == .testing {
            app.logger.warning(
                "\(reason) APNS is disabled for \(app.environment.name).",
                metadata: [
                    "apnsPrivateKeyPath": .string(privateKeyPath),
                    "error": .string(String(describing: error))
                ]
            )
            return
        }
        throw Abort(.internalServerError, reason: reason)
    }

    await app.apns.configure(authenticationMethod)

    app.logger.info(
        "APNS configured for worker runtime.",
        metadata: [
            "apnsConfigSource": .string("environment+mountedFile"),
            "apnsPrivateKeyPath": .string(privateKeyPath)
        ]
    )
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
