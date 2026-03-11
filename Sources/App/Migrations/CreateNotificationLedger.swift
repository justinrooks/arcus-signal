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
        try await db.schema(NotificationLedgerModel.schema)
            .field("created", .datetime, .required)     // consider enum later
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema).deleteField("created").update()
    }
}
