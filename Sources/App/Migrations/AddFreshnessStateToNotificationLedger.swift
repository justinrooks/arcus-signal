import Fluent
import SQLKit

struct AddFreshnessStateToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema)
            .field("freshness_state", .string)
            .update()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema)
            .deleteField("freshness_state")
            .update()
    }
}
