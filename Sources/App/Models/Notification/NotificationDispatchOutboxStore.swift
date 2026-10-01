import Fluent
import FluentSQL
import Foundation
import Vapor

struct NotificationDispatchClaim: Decodable, Sendable {
    let id: UUID
    let seriesId: UUID
    let revisionUrn: String
    let mode: String
    let reason: String
    let sourceTargetExecutionId: UUID?
    // Preserve PostgreSQL timestamp precision for the completion fence.
    let lease: String
}

struct NotificationDispatchOutboxStore {
    static let leaseSeconds = 300

    func claim(mode: String, limit: Int, now: Date = .now, on db: any Database) async throws -> [NotificationDispatchClaim] {
        guard limit > 0 else { return [] }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        // One statement commits the claim before the caller awaits Redis.
        return try await sql.raw("""
            WITH eligible AS (
                SELECT id, available_at
                FROM notification_outbox
                WHERE mode = \(bind: mode)
                  AND state IN ('ready', 'processing')
                  AND available_at <= \(bind: now)
                ORDER BY available_at, id
                LIMIT \(bind: limit)
                FOR UPDATE SKIP LOCKED
            ), claimed AS (
                UPDATE notification_outbox AS outbox
                SET state = 'processing',
                    available_at = \(bind: now.addingTimeInterval(TimeInterval(Self.leaseSeconds))),
                    updated = NOW()
                FROM eligible
                WHERE outbox.id = eligible.id
                RETURNING outbox.id, outbox.series_id AS "seriesId",
                          outbox.revision_urn AS "revisionUrn", outbox.mode, outbox.reason,
                          outbox.source_target_execution_id AS "sourceTargetExecutionId",
                          outbox.available_at::text AS lease,
                          eligible.available_at AS previous_availability
            )
            SELECT * FROM claimed ORDER BY previous_availability, id
            """).all(decoding: NotificationDispatchClaim.self)
    }

    func complete(_ claim: NotificationDispatchClaim, error: String? = nil, now: Date = .now, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let row = try await sql.raw("""
            UPDATE notification_outbox
            SET state = CASE WHEN \(bind: error)::text IS NULL THEN 'done'
                             WHEN attempts + 1 >= 3 THEN 'dead' ELSE 'ready' END,
                attempts = attempts + 1,
                last_error = \(bind: error),
                available_at = CASE WHEN \(bind: error)::text IS NULL THEN \(bind: now)
                                    ELSE \(bind: now) +
                                        CASE WHEN attempts = 0 THEN INTERVAL '30 seconds'
                                             ELSE INTERVAL '120 seconds' END END,
                updated = NOW()
            WHERE id = \(bind: claim.id)
              AND state = 'processing'
              AND available_at::text = \(bind: claim.lease)
            RETURNING id
            """).first()
        return row != nil
    }

    func resetForReplay(id: UUID, reason: NotificationReason, now: Date = .now, on db: any Database) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        // Recheck current state under the UPDATE lock: a preceding read may be stale.
        let row = try await sql.raw("""
            UPDATE notification_outbox
            SET state = 'ready', reason = \(bind: reason.rawValue), attempts = 0,
                last_error = NULL, available_at = \(bind: now), updated = NOW()
            WHERE id = \(bind: id)
              AND state NOT IN ('done', 'processing')
              AND (state <> 'ready' OR available_at > \(bind: now) OR reason <> \(bind: reason.rawValue))
            RETURNING id
            """).first()
        return row != nil
    }
}
