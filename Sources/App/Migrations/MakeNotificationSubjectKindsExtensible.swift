import Fluent
import SQLKit
import Vapor

/// Replaces recognition constraints only; NWS foreign keys and dedupe indexes remain intact.
struct MakeNotificationSubjectKindsExtensible: AsyncMigration {
    private let tables = ["notification_outbox", "notification_ledger", "notification_debug", "notification_send_attempts"]

    func prepare(on database: any Database) async throws {
        try await replaceConstraints(on: database, extensible: true)
    }

    func revert(on database: any Database) async throws {
        // Restoring the allowlist refuses any future-kind data. Transactional DDL
        // leaves all four constraints intact if validation fails, even in the last table.
        try await replaceConstraints(on: database, extensible: false)
    }

    private func replaceConstraints(on database: any Database, extensible: Bool) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Notification subject identity requires SQLDatabase")
            }
            for table in tables {
                let identity: SQLQueryString = extensible ? """
                    subject_kind IS NOT NULL AND LENGTH(BTRIM(subject_kind, \(literal: NotificationSubject.identityWhitespace))) > 0
                    AND subject_id IS NOT NULL AND LENGTH(BTRIM(subject_id, \(literal: NotificationSubject.identityWhitespace))) > 0
                    AND subject_revision_id IS NOT NULL AND LENGTH(BTRIM(subject_revision_id, \(literal: NotificationSubject.identityWhitespace))) > 0
                    AND subject_revision_id = revision_urn
                    AND ((subject_kind = 'nws' AND series_id IS NOT NULL
                          AND subject_id = LOWER(series_id::text))
                         OR (subject_kind <> 'nws' AND series_id IS NULL))
                    """ : """
                    subject_id IS NOT NULL AND LENGTH(BTRIM(subject_id)) > 0
                    AND subject_revision_id IS NOT NULL AND subject_revision_id = revision_urn
                    AND ((subject_kind = 'nws' AND series_id IS NOT NULL
                          AND subject_id = LOWER(series_id::text))
                         OR (subject_kind = 'spc-meso' AND series_id IS NULL
                             AND LENGTH(BTRIM(subject_revision_id)) > 0))
                    """
                try await sql.raw("""
                    ALTER TABLE \(ident: table)
                    DROP CONSTRAINT \(ident: table + "_subject_identity_check"),
                    ADD CONSTRAINT \(ident: table + "_subject_identity_check") CHECK ((
                        (series_id IS NOT NULL AND subject_kind IS NULL
                         AND subject_id IS NULL AND subject_revision_id IS NULL)
                        OR (\(identity))
                    ) IS TRUE);
                    """).run()
            }
        }
    }
}
