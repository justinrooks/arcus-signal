import Fluent
import FluentSQL
import Vapor

struct AddNotificationDeliveryProvenance: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        // Existing deliveries remain unknown; completed_at cannot backfill a request start.
        try await sql.raw("""
            ALTER TABLE notification_ledger
              ADD COLUMN IF NOT EXISTS delivery_origin TEXT
                CHECK (delivery_origin IN ('alertDriven', 'presenceReconciliation')),
              ADD COLUMN IF NOT EXISTS first_apns_attempt_started_at TIMESTAMPTZ;
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NotificationLedgerModel.schema)
            .deleteField("delivery_origin")
            .deleteField("first_apns_attempt_started_at")
            .update()
    }
}
