//
//  CreateNotificationDebug.swift
//  ArcusSignal
//
//  Created by Codex on 4/9/26.
//

import Fluent
import SQLKit

struct CreateNotificationDebug: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(NotificationDebugModel.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("series_id", .uuid, .required,
                   .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))
            .field("installation_id", .uuid,
                   .references(DeviceInstallationModel.schema, "installation_id", onDelete: .setNull))
            .field("notification_ledger_id", .uuid,
                   .references(NotificationLedgerModel.schema, "id", onDelete: .setNull))
            .field("revision_urn", .string, .required)
            .field("mode", .string, .required)
            .field("reason", .string, .required)
            .field("record_kind", .string, .required)
            .field("title", .string, .required)
            .field("subtitle", .string, .required)
            .field("body", .string, .required)
            .field("created", .datetime)
            .unique(on: "notification_ledger_id")
            .create()

        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_debug_preview_unique
            ON notification_debug (series_id, revision_urn, mode, record_kind)
            WHERE record_kind = 'preview_no_candidates';
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_debug_series_created
            ON notification_debug (series_id, created DESC);
        """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_debug_preview_unique;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_debug_series_created;").run()
        }

        try await db.schema(NotificationDebugModel.schema).delete()
    }
}
