import Fluent
import FluentSQL
import Foundation
import Vapor

struct LedgerClaimResult {
    let inserted: Bool
    let id: UUID?
    let retryGeneration: Int?
}

struct NotificationRetryDelivery: Decodable, Sendable {
    let id: UUID
    let installationID: UUID
    let retryGeneration: Int

    enum CodingKeys: String, CodingKey {
        case id
        case installationID = "installationId"
        case retryGeneration
    }
}

struct NotificationDeliveryStore {
    func claim(
        installationID: UUID,
        seriesID: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        retryOwnerID: String? = nil,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let newID = UUID()

        let row = try await sql.raw("""
            INSERT INTO notification_ledger
                (id, installation_id, series_id, revision_urn, mode, reason, freshness_state,
                 retry_owner_id, retry_generation, created, status)
            VALUES
                (\(bind: newID),
                 \(bind: installationID),
                 \(bind: seriesID),
                 \(bind: revisionUrn),
                 \(bind: mode),
                 \(bind: reason),
                 \(bind: freshnessState),
                 \(bind: retryOwnerID),
                 0,
                 NOW(),
                'claimed')
            ON CONFLICT (installation_id, series_id, revision_urn)
            DO NOTHING
            RETURNING id, retry_generation AS "retryGeneration"
            """)
            .first()

        if let row {
            let returnedID = try row.decode(column: "id", as: UUID.self)
            return LedgerClaimResult(
                inserted: true,
                id: returnedID,
                retryGeneration: try row.decode(column: "retryGeneration", as: Int.self)
            )
        } else {
            return LedgerClaimResult(inserted: false, id: nil, retryGeneration: nil)
        }
    }

    func loadRetryingDeliveries(
        seriesID: UUID,
        revisionUrn: String,
        installationID: UUID?,
        retryOwnerID: String,
        on db: any Database
    ) async throws -> [NotificationRetryDelivery] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        return try await sql.raw("""
            SELECT id,
                   installation_id AS "installationId",
                   retry_generation AS "retryGeneration"
            FROM notification_ledger
            WHERE series_id = \(bind: seriesID)
              AND revision_urn = \(bind: revisionUrn)
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND (\(bind: installationID)::uuid IS NULL
                   OR installation_id = \(bind: installationID)::uuid)
            ORDER BY created, id
            """)
            .all(decoding: NotificationRetryDelivery.self)
    }

    func hasRetryInFlight(
        seriesID: UUID,
        revisionUrn: String,
        installationID: UUID?,
        retryOwnerID: String,
        on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        return try await sql.raw("""
            SELECT EXISTS (
                SELECT 1
                FROM notification_ledger
                WHERE series_id = \(bind: seriesID)
                  AND revision_urn = \(bind: revisionUrn)
                  AND status = 'claimed'
                  AND retry_owner_id = \(bind: retryOwnerID)
                  AND (\(bind: installationID)::uuid IS NULL
                       OR installation_id = \(bind: installationID)::uuid)
            ) AS "exists"
            """)
            .first()?
            .decode(column: "exists", as: Bool.self) ?? false
    }

    func reclaimRetrying(
        _ delivery: NotificationRetryDelivery,
        seriesID: UUID,
        revisionUrn: String,
        retryOwnerID: String,
        freshnessState: LocationFreshnessState,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'claimed',
                freshness_state = \(bind: freshnessState),
                completed_at = NULL
            WHERE id = \(bind: delivery.id)
              AND installation_id = \(bind: delivery.installationID)
              AND series_id = \(bind: seriesID)
              AND revision_urn = \(bind: revisionUrn)
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND retry_generation = \(bind: delivery.retryGeneration)
            RETURNING id, retry_generation AS "retryGeneration"
            """)
            .first()

        guard let row else {
            return .init(inserted: false, id: nil, retryGeneration: nil)
        }

        return .init(
            inserted: true,
            id: try row.decode(column: "id", as: UUID.self),
            retryGeneration: try row.decode(column: "retryGeneration", as: Int.self)
        )
    }

    func markRetrying(
        claimID: UUID?,
        retryOwnerID: String,
        retryGeneration: Int?,
        apnsErrorCode: String,
        on db: any Database
    ) async throws {
        guard let claimID, let retryGeneration else { throw Abort(.notFound) }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'retrying',
                apns_error_code = \(bind: apnsErrorCode),
                retry_generation = retry_generation + 1,
                completed_at = NULL
            WHERE id = \(bind: claimID)
              AND status = 'claimed'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND retry_generation = \(bind: retryGeneration)
            RETURNING id
            """)
            .first()

        guard row != nil else { throw Abort(.conflict) }
    }

    func completeSent(
        claimID: UUID?,
        on db: any Database
    ) async throws {
        guard let claimID else { return }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'sent',
                apns_error_code = NULL,
                completed_at = NOW()
            WHERE id = \(bind: claimID)
              AND status = 'claimed'
            RETURNING id
            """)
            .first()

        guard row == nil else { return }

        let existing = try await sql.raw("""
            SELECT id
            FROM notification_ledger
            WHERE id = \(bind: claimID)
            """)
            .first()
        guard existing != nil else { return }
        throw Abort(.conflict)
    }

    func completeRetryingFailure(
        _ delivery: NotificationRetryDelivery,
        seriesID: UUID,
        revisionUrn: String,
        retryOwnerID: String,
        apnsErrorCode: String,
        on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'failed',
                apns_error_code = \(bind: apnsErrorCode),
                completed_at = NOW()
            WHERE id = \(bind: delivery.id)
              AND installation_id = \(bind: delivery.installationID)
              AND series_id = \(bind: seriesID)
              AND revision_urn = \(bind: revisionUrn)
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND retry_generation = \(bind: delivery.retryGeneration)
            RETURNING id
            """)
            .first()

        return row != nil
    }

    func completeFailed(
        claimID: UUID?,
        apnsErrorCode: String?,
        on db: any Database
    ) async throws {
        guard let claimID else { throw Abort(.notFound) }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'failed',
                apns_error_code = COALESCE(\(bind: apnsErrorCode), apns_error_code),
                completed_at = NOW()
            WHERE id = \(bind: claimID)
              AND status IN ('claimed', 'retrying')
            RETURNING id
            """)
            .first()

        guard row != nil else { throw Abort(.notFound) }
    }

    func completeInvalidTokenFailure(
        claimID: UUID?,
        installationID: UUID,
        failedToken: String,
        apnsErrorCode: String,
        on db: any Database
    ) async throws {
        try await db.transaction { transaction in
            try await completeFailed(
                claimID: claimID,
                apnsErrorCode: apnsErrorCode,
                on: transaction
            )
            _ = try await deactivateInstallationIfTokenMatches(
                installationID: installationID,
                apnsToken: failedToken,
                on: transaction
            )
        }
    }

    func failRetryingDeliveries(
        seriesID: UUID,
        revisionUrn: String,
        installationID: UUID?,
        retryOwnerID: String,
        apnsErrorCode: String,
        on db: any Database
    ) async throws -> Int {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let rows = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'failed',
                apns_error_code = \(bind: apnsErrorCode),
                completed_at = NOW()
            WHERE series_id = \(bind: seriesID)
              AND revision_urn = \(bind: revisionUrn)
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND (\(bind: installationID)::uuid IS NULL
                   OR installation_id = \(bind: installationID)::uuid)
            RETURNING id
            """)
            .all()

        return rows.count
    }

    func deactivateInstallationIfTokenMatches(
        installationID: UUID,
        apnsToken: String,
        on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE device_installations
            SET is_active = FALSE,
                updated_at = NOW()
            WHERE installation_id = \(bind: installationID)
              AND apns_device_token = \(bind: apnsToken)
              AND is_active = TRUE
            RETURNING installation_id
            """)
            .first()

        return row != nil
    }
}
