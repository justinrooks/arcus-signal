import Fluent
import SQLKit

struct AddFreshnessStateToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(NotificationLedgerModel.schema)
                .field("freshness_state", .string)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS freshness_state TEXT;
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema)
            .deleteField("freshness_state")
            .update()
    }
}
