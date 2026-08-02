@testable import App
import Fluent
import FluentPostgresDriver
import Vapor

enum IntegrationTestApplicationSetup: Sendable {
    case directPostgres
    case configured(mode: AppRuntimeMode, migrate: Bool)
}

func withIntegrationTestApplication(
    setup: IntegrationTestApplicationSetup,
    prepare: (Application) async throws -> Void = { _ in },
    test: (Application) async throws -> Void
) async throws {
    let app = try await Application.make(.testing)

    do {
        switch setup {
        case .directPostgres:
            app.databases.use(
                try .postgres(url: integrationTestDatabaseURL()),
                as: .psql
            )
        case let .configured(mode, migrate):
            try await configure(app, mode: mode)
            if migrate {
                try await app.autoMigrate()
            }
        }

        try await prepare(app)
        try await test(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }

    try await app.asyncShutdown()
}

func withRollbackTransaction(
    on app: Application,
    test: @escaping @Sendable (any Database) async throws -> Void
) async throws {
    do {
        try await app.db.transaction { database in
            try await test(database)
            throw RollbackAfterAssertions.afterAssertions
        }
    } catch RollbackAfterAssertions.afterAssertions {
        // Expected: keep shared integration-test tables unchanged.
    }
}

private func integrationTestDatabaseURL() -> String {
    Environment.get("DATABASE_URL")
        ?? "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable"
}

private enum RollbackAfterAssertions: Error {
    case afterAssertions
}
