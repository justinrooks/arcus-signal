import Fluent
import SQLKit

struct CreateTargetDispatchOutbox: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ArcusTargetDispatchOutboxModel.schema)
            .id()
            .field("revision_urn", .string, .required)
            .unique(on: "revision_urn")
            .field("series_id", .uuid, .required, .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))
            .field("payload", .dictionary, .required)
            .field("attempt_count", .int, .required)
            .field("last_error", .string)
            .field("created", .datetime, .required)
            .field("dispatched", .datetime)
            .create()

        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE target_dispatch_outbox
              ALTER COLUMN attempt_count SET DEFAULT 0,
              ALTER COLUMN created SET DEFAULT now();
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_target_dispatch_outbox_pending
            ON target_dispatch_outbox (dispatched, created);
        """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ArcusTargetDispatchOutboxModel.schema).delete()
    }
}
