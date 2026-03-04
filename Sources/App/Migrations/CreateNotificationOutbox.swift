//
//  CreateNotificationOutbox.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/3/26.
//

import Fluent
import SQLKit

struct CreateNotificationOutbox: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ArcusNotificationOutboxModel.schema)
            .field("id", .uuid, .identifier(auto: false))

            .field("series_id", .uuid, .required,
                   .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))

            .field("revision_urn", .string, .required)
            .field("mode", .string, .required)      // consider enum later
            .field("state", .string, .required)     // consider enum later

            .field("attempts", .int, .required)
            .field("last_error", .string)

            .field("available_at", .datetime, .required)

            .field("created", .datetime)
            .field("updated", .datetime)

            // Prevent duplicate enqueue for same series+revision+mode
            .unique(on: "series_id", "revision_urn", "mode")

            .create()
        
        // Postgres-only indexes
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_outbox_state_available_at
            ON notification_outbox (state, available_at);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_outbox_series_id
            ON notification_outbox (series_id);
        """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_outbox_state_available_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_outbox_series_id;").run()
        }
        try await db.schema(ArcusNotificationOutboxModel.schema).delete()
    }
}
