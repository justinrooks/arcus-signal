import Fluent
import FluentSQL
import Foundation
import Vapor

struct PresenceReconciliationOutboxInsertResult: Sendable {
    let inserted: Bool
    let id: UUID?
}

struct PresenceReconciliationOutboxStore: Sendable {
    func insert(
        installationID: UUID,
        presenceCapturedAt: Date,
        triggerCategory: PresenceReconciliationTriggerCategory,
        targetingFingerprint: String,
        availableAt: Date = .now,
        on database: any Database
    ) async throws -> PresenceReconciliationOutboxInsertResult {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            INSERT INTO presence_reconciliation_outbox
                (id, installation_id, presence_captured_at, trigger_category,
                 targeting_fingerprint, state, attempt_count, available_at,
                 created_at, updated_at)
            VALUES
                (gen_random_uuid(), \(bind: installationID), \(bind: presenceCapturedAt),
                 \(bind: triggerCategory.rawValue), \(bind: targetingFingerprint),
                 \(bind: PresenceReconciliationOutboxState.ready.rawValue), 0,
                 \(bind: availableAt), NOW(), NOW())
            ON CONFLICT (installation_id, presence_captured_at, trigger_category, targeting_fingerprint)
            DO NOTHING
            RETURNING id
            """).first()

        guard let row else {
            return PresenceReconciliationOutboxInsertResult(inserted: false, id: nil)
        }

        return PresenceReconciliationOutboxInsertResult(
            inserted: true,
            id: try row.decode(column: "id", as: UUID.self)
        )
    }

    func readyIntents(
        availableThrough cutoff: Date,
        limit: Int,
        on database: any Database
    ) async throws -> [PresenceReconciliationOutboxModel] {
        try await PresenceReconciliationOutboxModel.query(on: database)
            .filter(\.$stateRaw == PresenceReconciliationOutboxState.ready.rawValue)
            .filter(\.$availableAt <= cutoff)
            .sort(\.$availableAt, .ascending)
            .sort(\.$createdAt, .ascending)
            .sort(\.$id, .ascending)
            .limit(limit)
            .all()
    }

    func recordQueueHandoffSuccess(
        intentID: UUID,
        on database: any Database
    ) async throws -> Bool {
        try await updateReadyIntent(
            id: intentID,
            set: """
                state = \(bind: PresenceReconciliationOutboxState.done.rawValue),
                attempt_count = attempt_count + 1,
                last_error = NULL,
                dispatched_at = NOW(),
                updated_at = NOW()
                """,
            on: database
        )
    }

    func recordQueueHandoffFailure(
        intentID: UUID,
        error: String,
        nextAvailableAt: Date,
        on database: any Database
    ) async throws -> Bool {
        try await updateReadyIntent(
            id: intentID,
            set: """
                attempt_count = attempt_count + 1,
                last_error = \(bind: error),
                available_at = \(bind: nextAvailableAt),
                updated_at = NOW()
                """,
            on: database
        )
    }

    func markDead(
        intentID: UUID,
        error: String,
        on database: any Database
    ) async throws -> Bool {
        try await updateReadyIntent(
            id: intentID,
            set: """
                state = \(bind: PresenceReconciliationOutboxState.dead.rawValue),
                last_error = \(bind: error),
                updated_at = NOW()
                """,
            on: database
        )
    }

    private func updateReadyIntent(
        id: UUID,
        set: SQLQueryString,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE presence_reconciliation_outbox
            SET \(set)
            WHERE id = \(bind: id)
              AND state = \(bind: PresenceReconciliationOutboxState.ready.rawValue)
            RETURNING id
            """).first()

        return row != nil
    }
}
