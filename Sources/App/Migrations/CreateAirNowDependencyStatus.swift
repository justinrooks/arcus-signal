import Fluent
import FluentSQL
import Vapor

struct CreateAirNowDependencyStatus: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS airnow_dependency_status (
                id TEXT PRIMARY KEY CHECK (id = 'airnow'),
                status JSONB NOT NULL
            )
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("airnow_dependency_status").delete()
    }
}
