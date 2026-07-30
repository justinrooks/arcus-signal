import Fluent
import FluentSQL
import Foundation
import Vapor

struct LedgerClaimResult {
    let inserted: Bool
    let id: UUID?
}

struct NotificationDeliveryStore {
    func claim(
        installationID: UUID,
        seriesID: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let newID = UUID()

        let row = try await sql.raw("""
            INSERT INTO notification_ledger
                (id, installation_id, series_id, revision_urn, mode, reason, freshness_state, created, status)
            VALUES
                (\(bind: newID),
                 \(bind: installationID),
                 \(bind: seriesID),
                 \(bind: revisionUrn),
                 \(bind: mode),
                 \(bind: reason),
                 \(bind: freshnessState),
                 NOW(),
                'claimed')
            ON CONFLICT (installation_id, series_id, revision_urn)
            DO NOTHING
            RETURNING id
            """)
            .first()

        if let row {
            let returnedID = try row.decode(column: "id", as: UUID.self)
            return LedgerClaimResult(inserted: true, id: returnedID)
        } else {
            return LedgerClaimResult(inserted: false, id: nil)
        }
    }

    func completeSent(
        claimID: UUID?,
        on db: any Database
    ) async throws {
        guard let claim = try await NotificationLedgerModel.find(claimID, on: db) else {
            return
        }

        claim.status = "sent"
        claim.completedAt = .now
        try await claim.save(on: db)
    }

    func completeFailed(
        claimID: UUID?,
        apnsErrorCode: String?,
        on db: any Database
    ) async throws {
        guard let claim = try await NotificationLedgerModel.find(claimID, on: db) else {
            throw Abort(.notFound)
        }

        if let apnsErrorCode {
            claim.apnsErrorCode = apnsErrorCode
        }
        claim.status = "failed"
        claim.completedAt = .now
        try await claim.save(on: db)
    }
}
