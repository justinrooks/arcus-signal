import Fluent
import SQLKit
import Vapor

struct CreatePipelineStageTimings: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        // Correlation is independent of best-effort timing rows; deliberately no timing FK.
        try await sql.raw("ALTER TABLE notification_outbox ADD COLUMN IF NOT EXISTS source_target_execution_id UUID").run()
        // No historical backfill: outbox completion/update times are not execution boundaries.
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS target_pipeline_timings (
                execution_id UUID PRIMARY KEY,
                revision_urn TEXT NOT NULL,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                queued_at TIMESTAMPTZ,
                started_at TIMESTAMPTZ NOT NULL,
                h3_completed_at TIMESTAMPTZ
            );
            """).run()
        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_pipeline_timings (
                delivery_attempt_id UUID PRIMARY KEY,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL CHECK (mode IN ('h3', 'ugc')),
                queued_at TIMESTAMPTZ,
                started_at TIMESTAMPTZ NOT NULL,
                candidate_resolution_completed_at TIMESTAMPTZ,
                source_target_execution_id UUID
            );
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_target_pipeline_revision
                ON target_pipeline_timings (series_id, revision_urn);
            """).run()
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_pipeline_revision
                ON notification_pipeline_timings (series_id, revision_urn, mode);
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("notification_outbox").deleteField("source_target_execution_id").update()
        try await db.schema("notification_pipeline_timings").delete()
        try await db.schema("target_pipeline_timings").delete()
    }
}
