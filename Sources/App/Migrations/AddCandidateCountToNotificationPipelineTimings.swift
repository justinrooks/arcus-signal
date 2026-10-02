import Fluent
import SQLKit
import Vapor

struct AddCandidateCountToNotificationPipelineTimings: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            ALTER TABLE notification_pipeline_timings
            ADD COLUMN IF NOT EXISTS candidate_count INTEGER CHECK (candidate_count >= 0)
            """).run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            ALTER TABLE notification_pipeline_timings
            DROP COLUMN IF EXISTS candidate_count
            """).run()
    }
}
