import Fluent
import SQLKit

struct CreatePresenceReconciliationOutbox: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(PresenceReconciliationOutboxModel.schema)
            .id()
            .field(
                "installation_id",
                .uuid,
                .required,
                .references(DeviceInstallationModel.schema, "installation_id", onDelete: .cascade)
            )
            .field("presence_captured_at", .datetime, .required)
            .field("trigger_category", .string, .required)
            .field("targeting_fingerprint", .string, .required)
            .field("state", .string, .required)
            .field("attempt_count", .int, .required)
            .field("last_error", .string)
            .field("available_at", .datetime, .required)
            .field("dispatched_at", .datetime)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .unique(on: "installation_id", "presence_captured_at", "trigger_category", "targeting_fingerprint")
            .create()

        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE presence_reconciliation_outbox
              ALTER COLUMN attempt_count SET DEFAULT 0,
              ALTER COLUMN available_at SET DEFAULT now(),
              ALTER COLUMN created_at SET DEFAULT now(),
              ALTER COLUMN updated_at SET DEFAULT now();
            """).run()

        try await sql.raw("""
            ALTER TABLE presence_reconciliation_outbox
              ADD CONSTRAINT presence_reconciliation_outbox_state_check
              CHECK (state IN ('ready', 'done', 'dead')),
              ADD CONSTRAINT presence_reconciliation_outbox_trigger_category_check
              CHECK (trigger_category IN ('firstUsablePresence', 'movedWhileUsable', 'becameUsable')),
              ADD CONSTRAINT presence_reconciliation_outbox_attempt_count_check
              CHECK (attempt_count >= 0);
            """).run()

        try await sql.raw("""
            CREATE INDEX idx_presence_reconciliation_outbox_ready
            ON presence_reconciliation_outbox (state, available_at, created_at, id);
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(PresenceReconciliationOutboxModel.schema).delete()
    }
}
