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
    // Preserve existing NWS callers; all claims now write explicit subject identity.
    func claim(
        installationID: UUID, seriesID: UUID, revisionUrn: String,
        mode: NotificationTargetMode, reason: NotificationReason,
        freshnessState: LocationFreshnessState, retryOwnerID: String? = nil,
        origin: NotificationDeliveryOrigin? = nil, on db: any Database
    ) async throws -> LedgerClaimResult {
        try await claim(
            installationID: installationID, subject: .nws(seriesID: seriesID, revisionUrn: revisionUrn),
            mode: mode, reason: reason, freshnessState: freshnessState,
            retryOwnerID: retryOwnerID, origin: origin, on: db
        )
    }

    private func subjectIdentity(_ subject: NotificationSubject) -> SQLQueryString {
        if subject.kind == .nws {
            guard let seriesID = subject.nwsSeriesID,
                  subject.productID == seriesID.uuidString.lowercased() else { return "FALSE" }
            // DB constraints equate explicit NWS subjects with these columns;
            // legacy rows retain them too. Keep the existing identity index usable.
            return """
            series_id = \(bind: seriesID)
            AND revision_urn = \(bind: subject.revisionID)
            """
        }
        // Non-NWS rows always carry an explicit tuple. This predicate also
        // establishes eligibility for the partial subject-identity index.
        return """
        series_id IS NULL
        AND subject_kind = \(bind: subject.kind.rawValue)
        AND subject_id = \(bind: subject.productID)
        AND subject_revision_id = \(bind: subject.revisionID)
        """
    }

    func claim(
        installationID: UUID,
        subject: NotificationSubject,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        retryOwnerID: String? = nil,
        origin: NotificationDeliveryOrigin? = nil,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        guard let seriesID = subject.nwsSeriesID else {
            throw Abort(.badRequest, reason: "NWS claim requires an NWS notification subject")
        }
        let newID = UUID()

        let row = try await sql.raw("""
            INSERT INTO notification_ledger
                (id, installation_id, series_id, revision_urn, subject_kind, subject_id, subject_revision_id,
                 mode, reason, freshness_state,
                 retry_owner_id, delivery_origin, retry_generation, created, status)
            VALUES
                (\(bind: newID),
                 \(bind: installationID),
                 \(bind: seriesID),
                 \(bind: subject.revisionID),
                 \(bind: subject.kind.rawValue),
                 \(bind: subject.productID),
                 \(bind: subject.revisionID),
                 \(bind: mode),
                 \(bind: reason),
                 \(bind: freshnessState),
                 \(bind: retryOwnerID),
                 \(bind: origin?.rawValue),
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

    /// Event-first, presence-first and fanout producers must all use this claim.
    /// Only a winner may proceed to delivery; duplicates never acquire retry ownership.
    func claimMeso(
        installationID: UUID,
        issueYear: Int,
        number: Int,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        retryOwnerID: String,
        origin: NotificationDeliveryOrigin,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        let row = try await sql.raw("""
            INSERT INTO notification_ledger
                (id, installation_id, revision_urn, subject_kind, subject_id, subject_revision_id,
                 mode, reason, freshness_state, retry_owner_id, delivery_origin, retry_generation, created, status)
            VALUES
                (\(bind: UUID()), \(bind: installationID), \(bind: subject.revisionID),
                 \(bind: subject.kind.rawValue), \(bind: subject.productID), \(bind: subject.revisionID),
                 \(bind: mode), \(bind: reason), \(bind: freshnessState),
                 \(bind: retryOwnerID), \(bind: origin.rawValue), 0, NOW(), 'claimed')
            ON CONFLICT (installation_id, subject_kind, subject_id, subject_revision_id)
                WHERE series_id IS NULL
            DO NOTHING
            RETURNING id, retry_generation AS "retryGeneration"
            """).first()
        guard let row else { return .init(inserted: false, id: nil, retryGeneration: nil) }
        return .init(inserted: true, id: try row.decode(column: "id", as: UUID.self),
                     retryGeneration: try row.decode(column: "retryGeneration", as: Int.self))
    }

    /// Retry the same ledger row, fenced by product, installation, owner and generation.
    func reclaimRetryingMeso(
        _ delivery: NotificationRetryDelivery,
        issueYear: Int,
        number: Int,
        retryOwnerID: String,
        freshnessState: LocationFreshnessState,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'claimed', freshness_state = \(bind: freshnessState), completed_at = NULL
            WHERE id = \(bind: delivery.id)
              AND installation_id = \(bind: delivery.installationID)
              AND series_id IS NULL
              AND subject_kind = \(bind: subject.kind.rawValue)
              AND subject_id = \(bind: subject.productID)
              AND subject_revision_id = \(bind: subject.revisionID)
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND retry_generation = \(bind: delivery.retryGeneration)
            RETURNING id, retry_generation AS "retryGeneration"
            """).first()
        guard let row else { return .init(inserted: false, id: nil, retryGeneration: nil) }
        return .init(inserted: true, id: try row.decode(column: "id", as: UUID.self),
                     retryGeneration: try row.decode(column: "retryGeneration", as: Int.self))
    }

    func loadRetryingMesoDeliveries(
        issueYear: Int, number: Int, installationID: UUID? = nil,
        retryOwnerID: String, on db: any Database
    ) async throws -> [NotificationRetryDelivery] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        return try await sql.raw("""
            SELECT id, installation_id AS "installationId", retry_generation AS "retryGeneration"
            FROM notification_ledger
            WHERE series_id IS NULL
              AND subject_kind = \(bind: subject.kind.rawValue)
              AND subject_id = \(bind: subject.productID)
              AND subject_revision_id = \(bind: subject.revisionID)
              AND status = 'retrying' AND retry_owner_id = \(bind: retryOwnerID)
              AND (\(bind: installationID)::uuid IS NULL OR installation_id = \(bind: installationID)::uuid)
            ORDER BY created, id
            """).all(decoding: NotificationRetryDelivery.self)
    }

    func hasMesoRetryInFlight(
        issueYear: Int, number: Int, installationID: UUID? = nil,
        retryOwnerID: String, on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        return try await sql.raw("""
            SELECT EXISTS (
                SELECT 1 FROM notification_ledger
                WHERE series_id IS NULL
                  AND subject_kind = \(bind: subject.kind.rawValue)
                  AND subject_id = \(bind: subject.productID)
                  AND subject_revision_id = \(bind: subject.revisionID)
                  AND status = 'claimed' AND retry_owner_id = \(bind: retryOwnerID)
                  AND (\(bind: installationID)::uuid IS NULL OR installation_id = \(bind: installationID)::uuid)
            ) AS "exists"
            """).first()?.decode(column: "exists", as: Bool.self) ?? false
    }

    func completeRetryingMesoFailure(
        _ delivery: NotificationRetryDelivery,
        issueYear: Int, number: Int, retryOwnerID: String,
        apnsErrorCode: String, on db: any Database
    ) async throws -> Bool {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        let row = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'failed', apns_error_code = \(bind: apnsErrorCode), completed_at = NOW()
            WHERE id = \(bind: delivery.id) AND installation_id = \(bind: delivery.installationID)
              AND series_id IS NULL
              AND subject_kind = \(bind: subject.kind.rawValue)
              AND subject_id = \(bind: subject.productID)
              AND subject_revision_id = \(bind: subject.revisionID)
              AND status = 'retrying' AND retry_owner_id = \(bind: retryOwnerID)
              AND retry_generation = \(bind: delivery.retryGeneration)
            RETURNING id
            """).first()
        return row != nil
    }

    func failRetryingMesoDeliveries(
        issueYear: Int, number: Int, installationID: UUID? = nil,
        retryOwnerID: String, apnsErrorCode: String, on db: any Database
    ) async throws -> Int {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let subject = NotificationSubject.spcMeso(issueYear: issueYear, number: number)
        let rows = try await sql.raw("""
            UPDATE notification_ledger
            SET status = 'failed', apns_error_code = \(bind: apnsErrorCode), completed_at = NOW()
            WHERE series_id IS NULL
              AND subject_kind = \(bind: subject.kind.rawValue)
              AND subject_id = \(bind: subject.productID)
              AND subject_revision_id = \(bind: subject.revisionID)
              AND status = 'retrying' AND retry_owner_id = \(bind: retryOwnerID)
              AND (\(bind: installationID)::uuid IS NULL OR installation_id = \(bind: installationID)::uuid)
            RETURNING id
            """).all()
        return rows.count
    }

    func loadRetryingDeliveries(
        subject: NotificationSubject,
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
            WHERE \(subjectIdentity(subject))
              AND status = 'retrying'
              AND retry_owner_id = \(bind: retryOwnerID)
              AND (\(bind: installationID)::uuid IS NULL
                   OR installation_id = \(bind: installationID)::uuid)
            ORDER BY created, id
            """)
            .all(decoding: NotificationRetryDelivery.self)
    }

    func hasRetryInFlight(
        subject: NotificationSubject,
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
                WHERE \(subjectIdentity(subject))
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
        subject: NotificationSubject,
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
              AND \(subjectIdentity(subject))
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
        firstAttemptStartedAt: Date? = nil,
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
                first_apns_attempt_started_at = CASE WHEN retry_generation = 0
                    THEN COALESCE(first_apns_attempt_started_at, \(bind: firstAttemptStartedAt))
                    ELSE first_apns_attempt_started_at END,
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
        firstAttemptStartedAt: Date? = nil,
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
                first_apns_attempt_started_at = CASE WHEN retry_generation = 0
                    THEN COALESCE(first_apns_attempt_started_at, \(bind: firstAttemptStartedAt))
                    ELSE first_apns_attempt_started_at END,
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
        subject: NotificationSubject,
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
              AND \(subjectIdentity(subject))
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
        firstAttemptStartedAt: Date? = nil,
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
                first_apns_attempt_started_at = CASE WHEN retry_generation = 0
                    THEN COALESCE(first_apns_attempt_started_at, \(bind: firstAttemptStartedAt))
                    ELSE first_apns_attempt_started_at END,
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
        firstAttemptStartedAt: Date? = nil,
        on db: any Database
    ) async throws {
        try await db.transaction { transaction in
            try await completeFailed(
                claimID: claimID,
                apnsErrorCode: apnsErrorCode,
                firstAttemptStartedAt: firstAttemptStartedAt,
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
        subject: NotificationSubject,
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
            WHERE \(subjectIdentity(subject))
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
