import Fluent
import SQLKit

struct CreateAlertRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(ArcusEventRevisionModel.schema)
            .id()
            .field("revision_urn", .string, .identifier(auto: false))
            .field("series_id", .uuid, .required,
                   .references("alert_series", "series_id", onDelete: .cascade))

            .field("message_type", .string, .required)
            .field("sent", .datetime, .required)
            .field("received", .datetime, .required)
            .field("referenced_urns", .array(of: .string), .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE alert_revision_index
              ALTER COLUMN received SET DEFAULT now(),
              ALTER COLUMN referenced_urns SET DEFAULT '{}'::text[];
            """).run()

        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_revision_index_series_id ON alert_revision_index(series_id);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_revision_index_sent ON alert_revision_index(sent);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS gin_revision_index_referenced_urns ON alert_revision_index USING GIN (referenced_urns);").run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(ArcusEventRevisionModel.schema).delete()
    }
}
