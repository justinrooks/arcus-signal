import Fluent

struct CreateNotificationMissedDecisions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(NotificationMissedDecisionModel.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("installation_id", .uuid, .required,
                   .references(DeviceInstallationModel.schema, "installation_id", onDelete: .cascade))
            .field("series_id", .uuid, .required,
                   .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))
            .field("revision_urn", .string, .required)
            .field("mode", .string, .required)
            .field("reason", .string, .required)
            .field("freshness_state", .string, .required)
            .field("miss_reason", .string, .required)
            .field("permission_mode", .string, .required)
            .field("captured_at", .datetime, .required)
            .field("received_at", .datetime, .required)
            .field("evaluated_at", .datetime, .required)
            .field("created", .datetime, .required)
            .unique(on: "installation_id", "series_id", "revision_urn", "mode", "reason", "miss_reason")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationMissedDecisionModel.schema).delete()
    }
}
