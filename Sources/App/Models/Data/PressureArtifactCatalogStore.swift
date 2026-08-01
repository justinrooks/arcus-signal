import Fluent
import FluentSQL
import Foundation
import Vapor

struct PressureArtifactCatalogStore: Sendable {
    func expireReadyArtifacts(
        before cutoff: Date,
        on database: any Database
    ) async throws -> Int {
        let readyRows = try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.ready.rawValue)
            .all()

        var expiredCount = 0
        for row in readyRows where row.validTime < cutoff {
            row.status = .expired
            try await row.save(on: database)
            expiredCount += 1
        }

        return expiredCount
    }

    func claimDeletionCandidate(
        for row: PressureArtifactCatalogModel,
        olderThan cutoff: Date,
        cleanupLeaseExpiresAt: Date,
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        guard let rowID = row.id,
              let sql = database as? any SQLDatabase else {
            return nil
        }

        let claimToken = UUID()
        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET claim_token = \(bind: claimToken),
                lease_expires_at = \(bind: cleanupLeaseExpiresAt)
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
              AND updated_at <= \(bind: cutoff)
              AND (
                (
                  claim_token IS NULL
                  AND (
                    lease_expires_at IS NULL
                    OR lease_expires_at <= NOW()
                  )
                )
                OR lease_expires_at <= NOW()
              )
            RETURNING id
            """)
            .first()

        guard updatedRow != nil else {
            return nil
        }

        return try await PressureArtifactCatalogModel.find(rowID, on: database)
    }

    func completeSuccessfulCleanup(
        for row: PressureArtifactCatalogModel,
        claimToken: UUID?,
        on database: any Database
    ) async throws -> Bool {
        guard let claimToken,
              let rowID = row.id,
              let sql = database as? any SQLDatabase else {
            return false
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET local_path = NULL,
                byte_size = NULL,
                error_summary = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func completeFailedCleanup(
        for row: PressureArtifactCatalogModel,
        claimToken: UUID?,
        reason: String,
        on database: any Database
    ) async throws -> Bool {
        guard let claimToken,
              let rowID = row.id,
              let sql = database as? any SQLDatabase else {
            return false
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET error_summary = \(bind: reason),
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func releaseCleanupClaim(
        for row: PressureArtifactCatalogModel,
        claimToken: UUID?,
        on database: any Database
    ) async throws -> Bool {
        guard let claimToken,
              let rowID = row.id,
              let sql = database as? any SQLDatabase else {
            return false
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET claim_token = NULL,
                lease_expires_at = NULL
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func ownsCleanupClaim(
        for row: PressureArtifactCatalogModel,
        claimToken: UUID?,
        on database: any Database
    ) async throws -> Bool {
        guard let claimToken,
              let rowID = row.id,
              let sql = database as? any SQLDatabase else {
            return false
        }

        let currentRow = try await sql.raw("""
            SELECT id
            FROM pressure_artifact_catalog
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
              AND claim_token = \(bind: claimToken)
            LIMIT 1
            """)
            .first()

        return currentRow != nil
    }

    func ensureCatalogRowExists(
        for payload: PressureArtifactWarmJobPayload,
        on database: any Database
    ) async throws {
        if try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        ) != nil {
            return
        }

        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: .pending
        )

        do {
            try await row.create(on: database)
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                return
            }

            throw error
        }
    }

    func claimCatalogRow(
        for payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        leaseExpiresAt: Date,
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.warming.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = \(bind: claimToken),
                lease_expires_at = \(bind: leaseExpiresAt)
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND (
                status IN (\(bind: PressureArtifactCatalogStatus.pending.rawValue),
                           \(bind: PressureArtifactCatalogStatus.failed.rawValue))
                OR (
                    status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
                    AND claim_token IS NULL
                    AND (
                        lease_expires_at IS NULL
                        OR lease_expires_at <= NOW()
                    )
                )
              )
            RETURNING id
            """)
            .first()

        guard row != nil else {
            return nil
        }

        return try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        )
    }

    func markReady(
        payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        localPath: String,
        byteSize: Int64,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.ready.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = \(bind: localPath),
                byte_size = \(bind: byteSize),
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func markFailed(
        payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        errorSummary: String,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = \(bind: errorSummary),
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func claimWarmableCatalogRow(
        for payload: PressureArtifactWarmJobPayload,
        recoveryCutoff: Date,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            INSERT INTO pressure_artifact_catalog (
                id,
                run_time,
                forecast_hour,
                valid_time,
                product,
                field_set_version,
                status,
                source,
                last_checked_at,
                error_summary,
                local_path,
                byte_size,
                claim_token,
                lease_expires_at
            ) VALUES (
                gen_random_uuid(),
                \(bind: payload.runTime),
                \(bind: payload.forecastHour),
                \(bind: payload.validTime),
                \(bind: payload.product.rawValue),
                \(bind: payload.fieldSetVersion.rawValue),
                \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                \(bind: PressureArtifactCatalogSource.aws.rawValue),
                NOW(),
                NULL,
                NULL,
                NULL,
                NULL,
                NULL
            )
            ON CONFLICT (run_time, forecast_hour, product, field_set_version)
            DO UPDATE SET
                status = \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE pressure_artifact_catalog.status IN (
                \(bind: PressureArtifactCatalogStatus.failed.rawValue)
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.pending.rawValue)
                AND pressure_artifact_catalog.last_checked_at < \(bind: recoveryCutoff)
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
                AND (
                    pressure_artifact_catalog.lease_expires_at IS NULL
                    OR pressure_artifact_catalog.lease_expires_at <= NOW()
                )
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
                AND pressure_artifact_catalog.claim_token IS NULL
                AND (
                    pressure_artifact_catalog.lease_expires_at IS NULL
                    OR pressure_artifact_catalog.lease_expires_at <= NOW()
                )
            )
            RETURNING id
            """)
            .first()

        return row != nil
    }

    func recoverUnusableReadyCatalogRow(
        for payload: PressureArtifactWarmJobPayload,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.ready.rawValue)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func markUnavailability(
        payload: PressureArtifactWarmJobPayload,
        errorSummary: String,
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        _ = try await sql.raw("""
            INSERT INTO pressure_artifact_catalog (
                id,
                run_time,
                forecast_hour,
                valid_time,
                product,
                field_set_version,
                status,
                source,
                last_checked_at,
                error_summary
            ) VALUES (
                gen_random_uuid(),
                \(bind: payload.runTime),
                \(bind: payload.forecastHour),
                \(bind: payload.validTime),
                \(bind: payload.product.rawValue),
                \(bind: payload.fieldSetVersion.rawValue),
                \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                \(bind: PressureArtifactCatalogSource.aws.rawValue),
                NOW(),
                \(bind: errorSummary)
            )
            ON CONFLICT (run_time, forecast_hour, product, field_set_version)
            DO UPDATE SET
                last_checked_at = NOW()
            RETURNING id
            """)
            .first()
    }

    func markProbeFailure(
        payload: PressureArtifactWarmJobPayload,
        errorSummary: String,
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        _ = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = \(bind: errorSummary),
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
            RETURNING id
            """)
            .first()
    }
}
