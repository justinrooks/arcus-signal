import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

struct MesoNotificationDispatchClaim: Decodable, Sendable {
    let id: UUID
    let issueYear: Int
    let number: Int
    let lease: String
}

struct MesoNotificationOutboxStore {
    /// Called inside the canonical snapshot/coverage transaction and feed lock.
    func enqueue(issueYear: Int, number: Int, changed: Bool, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        try await sql.raw("""
            INSERT INTO notification_outbox
                (id, subject_kind, subject_id, subject_revision_id, revision_urn,
                 mode, reason, state, attempts, available_at, created, updated)
            VALUES (\(bind: UUID()), 'spc-meso', \(bind: subject.productID), \(bind: subject.revisionID),
                    \(bind: subject.revisionID), 'h3', 'new', 'ready', 0, NOW(), NOW(), NOW())
            ON CONFLICT (subject_kind, subject_id, subject_revision_id, mode) WHERE series_id IS NULL
            DO UPDATE SET state = 'ready', attempts = 0, available_at = NOW(), last_error = NULL, updated = NOW()
            WHERE \(bind: changed) AND notification_outbox.state IN ('done', 'dead')
            """).run()
    }

    func claim(limit: Int = 250, now: Date = .now, on db: any Database) async throws -> [MesoNotificationDispatchClaim] {
        guard limit > 0 else { return [] }
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        return try await sql.raw("""
            WITH eligible AS (
                SELECT o.id, s.issue_year, s.md_number, o.available_at
                FROM notification_outbox o JOIN spc_mesos s ON s.product_key = o.subject_id
                WHERE o.series_id IS NULL AND o.subject_kind = 'spc-meso'
                  AND o.subject_revision_id = 'initial' AND o.mode = 'h3'
                  AND o.state IN ('ready', 'processing') AND o.available_at <= \(bind: now)
                ORDER BY o.available_at, o.id LIMIT \(bind: limit)
                FOR UPDATE OF o SKIP LOCKED
            ), claimed AS (
                UPDATE notification_outbox o SET state = 'processing',
                    available_at = \(bind: now.addingTimeInterval(300)), updated = NOW()
                FROM eligible e WHERE o.id = e.id
                RETURNING o.id, e.issue_year AS "issueYear", e.md_number AS number,
                          o.available_at::text AS lease, e.available_at AS previous_availability
            ) SELECT * FROM claimed ORDER BY previous_availability, id
            """).all(decoding: MesoNotificationDispatchClaim.self)
    }

    func complete(_ claim: MesoNotificationDispatchClaim, error: String? = nil, now: Date = .now, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            UPDATE notification_outbox
            SET state = CASE WHEN \(bind: error)::text IS NULL THEN 'done'
                             WHEN attempts + 1 >= 3 THEN 'dead' ELSE 'ready' END,
                attempts = attempts + 1, last_error = \(bind: error),
                available_at = CASE WHEN \(bind: error)::text IS NULL THEN \(bind: now)
                    ELSE \(bind: now) + CASE WHEN attempts = 0 THEN INTERVAL '30 seconds'
                                            ELSE INTERVAL '120 seconds' END END, updated = NOW()
            WHERE id = \(bind: claim.id) AND state = 'processing' AND available_at::text = \(bind: claim.lease)
            """).run()
    }

    func dispatchPending(context: QueueContext) async throws {
        guard context.application.mesoNotificationsEnabled else { return }
        let pending = try await claim(on: context.application.db)
        for row in pending {
            do {
                try await context.application.queues.queue(ArcusQueueLane.send.queueName).dispatch(
                    MesoNotificationSendJob.self, .init(issueYear: row.issueYear, number: row.number),
                    maxRetryCount: MesoNotificationSendJob.maximumRetryCount
                )
            } catch {
                try await complete(row, error: String(reflecting: error), on: context.application.db)
                context.logger.error("Meso notification queue handoff failed.")
                continue
            }
            // A completion-write failure leaves the lease recoverable; the ledger
            // absorbs duplicate queue handoffs after recovery.
            try await complete(row, on: context.application.db)
        }
    }
}

struct DispatchMesoNotificationsScheduledJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        try await MesoNotificationOutboxStore().dispatchPending(context: context)
    }
}
