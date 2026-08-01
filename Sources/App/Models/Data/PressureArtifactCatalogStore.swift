import Fluent
import FluentSQL
import Foundation
import Vapor

struct PressureArtifactCatalogStore: Sendable {
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
}
