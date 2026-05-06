import Fluent
import SQLKit

struct CreateIngestSweepRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(IngestSweepRunModel.schema)
                .id()
                .field("source", .string, .required)
                .field("fixture_name", .string)
                .field("run_label", .string)
                .field("status", .string, .required)
                .field("started_at", .datetime, .required)
                .field("completed_at", .datetime, .required)
                .field("event_count", .int)
                .field("new_series_count", .int)
                .field("new_revision_count", .int)
                .field("target_outbox_queued_count", .int)
                .field("notification_outbox_queued_count", .int)
                .field("error_message", .string)
                .create()
            return
        }

        if try await !tableExists(sql: sql, table: IngestSweepRunModel.schema) {
            try await database.schema(IngestSweepRunModel.schema)
                .id()
                .field("source", .string, .required)
                .field("fixture_name", .string)
                .field("run_label", .string)
                .field("status", .string, .required)
                .field("started_at", .datetime, .required)
                .field("completed_at", .datetime, .required)
                .field("event_count", .int)
                .field("new_series_count", .int)
                .field("new_revision_count", .int)
                .field("target_outbox_queued_count", .int)
                .field("notification_outbox_queued_count", .int)
                .field("error_message", .string)
                .create()
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_ingest_sweep_runs_completed_at
            ON ingest_sweep_runs (completed_at DESC);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_ingest_sweep_runs_status_completed_at
            ON ingest_sweep_runs (status, completed_at DESC);
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_ingest_sweep_runs_completed_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_ingest_sweep_runs_status_completed_at;").run()
        }
        try await database.schema(IngestSweepRunModel.schema).delete()
    }
}

struct AddCompletedAtToNotificationLedger: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(NotificationLedgerModel.schema)
                .field("completed_at", .datetime)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE notification_ledger
            ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_ledger_status_completed_at
            ON notification_ledger (status, completed_at DESC);
        """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_ledger_status_completed_at;").run()
        }
        try await db.schema(NotificationLedgerModel.schema)
            .deleteField("completed_at")
            .update()
    }
}

struct AddCompletionFieldsToTargetDispatchOutbox: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema(ArcusTargetDispatchOutboxModel.schema)
                .field("completed", .datetime)
                .field("result", .string)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE target_dispatch_outbox
              ADD COLUMN IF NOT EXISTS completed TIMESTAMPTZ,
              ADD COLUMN IF NOT EXISTS result TEXT;
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_target_dispatch_outbox_result_completed
            ON target_dispatch_outbox (result, completed DESC);
        """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_target_dispatch_outbox_result_completed;").run()
        }
        try await db.schema(ArcusTargetDispatchOutboxModel.schema)
            .deleteField("completed")
            .deleteField("result")
            .update()
    }
}

struct CreateNotificationSendAttempts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(NotificationSendAttemptModel.schema)
                .id()
                .field("series_id", .uuid, .required,
                       .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))
                .field("revision_urn", .string, .required)
                .field("mode", .string, .required)
                .field("reason", .string, .required)
                .field("outcome", .string, .required)
                .field("no_op_reason", .string)
                .field("candidate_resolution_reached", .bool, .required)
                .field("candidate_count", .int, .required)
                .field("claimed_count", .int, .required)
                .field("sent_count", .int, .required)
                .field("failed_count", .int, .required)
                .field("attempted_at", .datetime, .required)
                .create()
            return
        }

        if try await !tableExists(sql: sql, table: NotificationSendAttemptModel.schema) {
            try await database.schema(NotificationSendAttemptModel.schema)
                .id()
                .field("series_id", .uuid, .required,
                       .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))
                .field("revision_urn", .string, .required)
                .field("mode", .string, .required)
                .field("reason", .string, .required)
                .field("outcome", .string, .required)
                .field("no_op_reason", .string)
                .field("candidate_resolution_reached", .bool, .required)
                .field("candidate_count", .int, .required)
                .field("claimed_count", .int, .required)
                .field("sent_count", .int, .required)
                .field("failed_count", .int, .required)
                .field("attempted_at", .datetime, .required)
                .create()
        }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_send_attempts_attempted_at
            ON notification_send_attempts (attempted_at DESC);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_send_attempts_outcome_attempted_at
            ON notification_send_attempts (outcome, attempted_at DESC);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_notification_send_attempts_no_op_reason_attempted_at
            ON notification_send_attempts (no_op_reason, attempted_at DESC);
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_send_attempts_attempted_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_send_attempts_outcome_attempted_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_notification_send_attempts_no_op_reason_attempted_at;").run()
        }
        try await database.schema(NotificationSendAttemptModel.schema).delete()
    }
}

struct CreateOperatorDashboardSnapshots: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(OperatorDashboardSnapshotModel.schema)
                .field("id", .string, .identifier(auto: false))
                .field("snapshot", .dictionary, .required)
                .field("created_at", .datetime)
                .field("updated_at", .datetime)
                .create()
            return
        }

        if try await !tableExists(sql: sql, table: OperatorDashboardSnapshotModel.schema) {
            try await database.schema(OperatorDashboardSnapshotModel.schema)
                .field("id", .string, .identifier(auto: false))
                .field("snapshot", .dictionary, .required)
                .field("created_at", .datetime)
                .field("updated_at", .datetime)
                .create()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OperatorDashboardSnapshotModel.schema).delete()
    }
}

private func tableExists(sql: any SQLDatabase, table: String) async throws -> Bool {
    let row = try await sql.raw("""
        SELECT EXISTS (
            SELECT 1
            FROM information_schema.tables
            WHERE table_schema = 'public' AND table_name = \(bind: table)
        ) AS exists;
        """).first()
    return try row?.decode(column: "exists", as: Bool.self) ?? false
}
