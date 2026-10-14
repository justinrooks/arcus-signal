import Fluent
import SQLKit
import Vapor

struct AddNotificationSubjectIdentity: AsyncMigration {
    private let tables = ["notification_outbox", "notification_ledger", "notification_debug", "notification_send_attempts"]

    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Notification subject identity requires SQLDatabase")
            }
            for table in tables {
                try await sql.raw("""
                    ALTER TABLE \(ident: table)
                      ADD COLUMN IF NOT EXISTS subject_kind TEXT,
                      ADD COLUMN IF NOT EXISTS subject_id TEXT,
                      ADD COLUMN IF NOT EXISTS subject_revision_id TEXT,
                      ALTER COLUMN series_id DROP NOT NULL;
                    """).run()
                try await sql.raw("""
                    UPDATE \(ident: table)
                    SET subject_kind = 'nws', subject_id = LOWER(series_id::text),
                        subject_revision_id = revision_urn
                    WHERE series_id IS NOT NULL
                      AND subject_kind IS NULL
                      AND subject_id IS NULL
                      AND subject_revision_id IS NULL;
                    """).run()
                // Keep legacy NWS inserts valid without triggers or changed SQL writers.
                // PostgreSQL CHECK accepts NULL, so require the expression to be TRUE.
                // Recreate the constraint so a retry also repairs an absent or
                // stale definition left by an interrupted deployment.
                try await sql.raw("""
                    ALTER TABLE \(ident: table)
                    DROP CONSTRAINT IF EXISTS \(ident: table + "_subject_identity_check"),
                    ADD CONSTRAINT \(ident: table + "_subject_identity_check") CHECK ((
                        (series_id IS NOT NULL AND subject_kind IS NULL
                         AND subject_id IS NULL AND subject_revision_id IS NULL)
                        OR
                        (subject_id IS NOT NULL AND LENGTH(BTRIM(subject_id)) > 0
                         AND subject_revision_id IS NOT NULL
                         AND subject_revision_id = revision_urn
                         AND ((subject_kind = 'nws' AND series_id IS NOT NULL
                               AND subject_id = LOWER(series_id::text))
                              OR (subject_kind = 'spc-meso' AND series_id IS NULL
                                  AND LENGTH(BTRIM(subject_revision_id)) > 0)))
                    ) IS TRUE);
                    """).run()
            }
            // Retain existing NWS uniqueness and its ON CONFLICT targets verbatim.
            // Non-CAP delivery identity excludes mode, just like the NWS ledger.
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_ledger_subject_identity
                ON notification_ledger (installation_id, subject_kind, subject_id, subject_revision_id)
                WHERE series_id IS NULL;
                """).run()
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_outbox_subject_identity
                ON notification_outbox (subject_kind, subject_id, subject_revision_id, mode)
                WHERE series_id IS NULL;
                """).run()
            try await sql.raw("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_debug_subject_preview
                ON notification_debug (subject_kind, subject_id, subject_revision_id, mode, record_kind)
                WHERE series_id IS NULL AND record_kind = 'preview_no_candidates';
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Notification subject identity requires SQLDatabase")
            }
            // SET NOT NULL deliberately refuses rollback if non-CAP records exist.
            // The transaction preserves every table and index on that failure.
            for table in tables {
                try await sql.raw("ALTER TABLE \(ident: table) ALTER COLUMN series_id SET NOT NULL;").run()
            }
            for index in ["idx_notification_ledger_subject_identity", "idx_notification_outbox_subject_identity", "idx_notification_debug_subject_preview"] {
                try await sql.raw("DROP INDEX \(ident: index);").run()
            }
            for table in tables {
                try await sql.raw("""
                    ALTER TABLE \(ident: table)
                      DROP CONSTRAINT \(ident: table + "_subject_identity_check"),
                      DROP COLUMN subject_kind,
                      DROP COLUMN subject_id,
                      DROP COLUMN subject_revision_id;
                    """).run()
            }
        }
    }
}
