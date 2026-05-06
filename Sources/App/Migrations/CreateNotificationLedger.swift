//
//  CreateNotificationLedger.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/10/26.
//

import Fluent
import SQLKit

struct CreateNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema)
            .field("id", .uuid, .identifier(auto: false))

            .field("installation_id", .uuid, .required,
                   .references(DeviceInstallationModel.schema, "installation_id", onDelete: .cascade))
        
            .field("series_id", .uuid, .required,
                   .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))

            .field("revision_urn", .string, .required)
            .field("mode", .string, .required)      // consider enum later
            .field("reason", .string, .required)     // consider enum later


            // Prevent duplicate enqueue for same series+revision+installation
            .unique(on: "installation_id", "series_id",  "revision_urn")

            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema).delete()
    }
}

struct AddCreatedToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(NotificationLedgerModel.schema)
                .field("created", .datetime, .required)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS created TIMESTAMPTZ;
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema).deleteField("created").update()
    }
}

struct AddStatusToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(NotificationLedgerModel.schema)
                .field("status", .string)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS status TEXT;
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema).deleteField("status").update()
    }
}

struct AddApnsErrorCodeToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(NotificationLedgerModel.schema)
                .field("apns_error_code", .string)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS apns_error_code TEXT;
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema).deleteField("apns_error_code").update()
    }
}
