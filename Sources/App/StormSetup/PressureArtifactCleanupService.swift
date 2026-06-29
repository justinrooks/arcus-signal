import Fluent
import FluentSQL
import Foundation
import Vapor

protocol PressureArtifactCleaning: Sendable {
    func cleanup(on application: Application, logger: Logger) async throws
}

struct PressureArtifactCleanupService: PressureArtifactCleaning, @unchecked Sendable {
    private let dateProvider: any StormSetupDateProviding
    private let fileManager: FileManager
    private let cacheRootURL: URL
    private let maxStaleAgeSeconds: TimeInterval
    private let deleteGraceSeconds: TimeInterval
    private let recoveryTimeoutSeconds: TimeInterval
    private let beforePhysicalRemovalHook: @Sendable () async -> Void

    init(
        dateProvider: any StormSetupDateProviding,
        fileManager: FileManager = .default,
        cacheRootURL: URL,
        maxStaleAgeSeconds: TimeInterval,
        deleteGraceSeconds: TimeInterval,
        recoveryTimeoutSeconds: TimeInterval,
        beforePhysicalRemovalHook: @escaping @Sendable () async -> Void = {}
    ) {
        self.dateProvider = dateProvider
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
        self.maxStaleAgeSeconds = max(0, maxStaleAgeSeconds)
        self.deleteGraceSeconds = max(0, deleteGraceSeconds)
        self.recoveryTimeoutSeconds = max(1, recoveryTimeoutSeconds)
        self.beforePhysicalRemovalHook = beforePhysicalRemovalHook
    }

    static func makeDefault(application: Application) -> PressureArtifactCleanupService {
        PressureArtifactCleanupService(
            dateProvider: SystemStormSetupDateProvider(),
            cacheRootURL: application.stormSetupConfiguration.pressureGribSubsetCacheRootURL,
            maxStaleAgeSeconds: application.stormSetupConfiguration.pressureArtifactMaxStaleAgeSeconds,
            deleteGraceSeconds: application.stormSetupConfiguration.pressureArtifactDeleteGraceSeconds,
            recoveryTimeoutSeconds: application.stormSetupConfiguration.pressureArtifactRecoveryTimeoutSeconds
        )
    }

    func cleanup(on application: Application, logger: Logger) async throws {
        let now = dateProvider.now()
        let expirationCutoff = now.addingTimeInterval(-maxStaleAgeSeconds)
        let deletionCutoff = now.addingTimeInterval(-deleteGraceSeconds)
        let cleanupLeaseExpiresAt = now.addingTimeInterval(recoveryTimeoutSeconds)

        let expiredRowsBeforeExpiration = try await loadExpiredRows(on: application.db)
        try await expireReadyArtifacts(before: expirationCutoff, on: application.db, logger: logger)
        let protectedPaths = try await loadProtectedPaths(on: application.db)
        try await deleteExpiredArtifacts(
            rows: expiredRowsBeforeExpiration,
            olderThan: deletionCutoff,
            cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
            protectedPaths: protectedPaths,
            on: application.db,
            logger: logger
        )
    }
}

extension PressureArtifactCleanupService {
    func expireReadyArtifacts(
        before cutoff: Date,
        on database: any Database,
        logger: Logger
    ) async throws {
        let readyRows = try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.ready.rawValue)
            .all()

        var expiredCount = 0
        for row in readyRows where row.validTime < cutoff {
            row.status = .expired
            try await row.save(on: database)
            expiredCount += 1
        }

        if expiredCount > 0 {
            logger.info(
                "Pressure artifact cleanup expired ready rows.",
                metadata: ["count": .stringConvertible(expiredCount)]
            )
        }
    }

    func deleteExpiredArtifacts(
        rows expiredRows: [PressureArtifactCatalogModel],
        olderThan cutoff: Date,
        cleanupLeaseExpiresAt: Date,
        protectedPaths: Set<String>,
        on database: any Database,
        logger: Logger
    ) async throws {
        let canonicalRootPath = canonicalPath(for: cacheRootURL)
        let canonicalRootPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"

        for row in expiredRows {
            guard let updatedAt = row.updatedAt, updatedAt <= cutoff else {
                continue
            }

            guard let claimedRow = try await claimDeletionCandidate(
                for: row,
                olderThan: cutoff,
                cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
                on: database
            ) else {
                continue
            }

            guard let localPath = claimedRow.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !localPath.isEmpty else {
                if try await completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
                    logger.info(
                        "Pressure artifact cleanup cleared missing file metadata.",
                        metadata: [
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
            let fileExists = fileManager.fileExists(atPath: localURL.path)

            guard fileExists else {
                guard localURL.path == canonicalRootPath || localURL.path.hasPrefix(canonicalRootPrefix) else {
                    if try await completeFailedCleanup(
                        for: claimedRow,
                        claimToken: claimedRow.claimToken,
                        reason: "cleanup path outside cache root",
                        on: database
                    ) {
                        logger.warning(
                            "Pressure artifact cleanup refused missing path outside cache root.",
                            metadata: [
                                "path": .string(localURL.path),
                                "runTime": .string(claimedRow.runTime.ISO8601Format()),
                                "forecastHour": .stringConvertible(claimedRow.forecastHour)
                            ]
                        )
                    } else {
                        logger.info(
                            "Pressure artifact cleanup lost claim ownership.",
                            metadata: cleanupClaimLostMetadata(for: claimedRow)
                        )
                    }
                    continue
                }

                if try await completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
                    logger.info(
                        "Pressure artifact cleanup cleared missing file metadata.",
                        metadata: [
                            "path": .string(localURL.path),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            let resolvedURL = localURL.resolvingSymlinksInPath()
            let canonicalPath = canonicalPath(for: resolvedURL)

            guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalRootPrefix) else {
                if try await completeFailedCleanup(
                    for: claimedRow,
                    claimToken: claimedRow.claimToken,
                    reason: "cleanup path outside cache root",
                    on: database
                ) {
                    logger.warning(
                        "Pressure artifact cleanup refused unsafe path.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            guard !isProtectedPath(canonicalPath, protectedPaths: protectedPaths) else {
                if try await releaseCleanupClaim(
                    for: claimedRow,
                    claimToken: claimedRow.claimToken,
                    on: database
                ) {
                    logger.info(
                        "Pressure artifact cleanup released claim for protected path.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            guard try await isPathCurrentlyProtected(canonicalPath, on: database) == false else {
                if try await releaseCleanupClaim(
                    for: claimedRow,
                    claimToken: claimedRow.claimToken,
                    on: database
                ) {
                    logger.info(
                        "Pressure artifact cleanup released claim for protected path.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                if try await completeFailedCleanup(
                    for: claimedRow,
                    claimToken: claimedRow.claimToken,
                    reason: "cleanup path is not a regular file",
                    on: database
                ) {
                    logger.warning(
                        "Pressure artifact cleanup refused non-regular path.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
                continue
            }

            await beforePhysicalRemovalHook()

            guard try await ownsCleanupClaim(for: claimedRow, claimToken: claimedRow.claimToken, on: database) else {
                logger.info(
                    "Pressure artifact cleanup lost claim ownership.",
                    metadata: cleanupClaimLostMetadata(for: claimedRow)
                )
                continue
            }

            do {
                try fileManager.removeItem(at: resolvedURL)
                if try await completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
                    logger.info(
                        "Pressure artifact deleted from cache.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour)
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
            } catch {
                try rethrowCancellationIfNeeded(error)
                if try await completeFailedCleanup(
                    for: claimedRow,
                    claimToken: claimedRow.claimToken,
                    reason: "cleanup delete failed: \(String(describing: error))",
                    on: database
                ) {
                    logger.error(
                        "Pressure artifact cleanup failed to delete file.",
                        metadata: [
                            "path": .string(canonicalPath),
                            "runTime": .string(claimedRow.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(claimedRow.forecastHour),
                            "error": .string(String(reflecting: error))
                        ]
                    )
                } else {
                    logger.info(
                        "Pressure artifact cleanup lost claim ownership.",
                        metadata: cleanupClaimLostMetadata(for: claimedRow)
                    )
                }
            }
        }
    }

    func loadExpiredRows(on database: any Database) async throws -> [PressureArtifactCatalogModel] {
        try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.expired.rawValue)
            .all()
    }

    func loadProtectedPaths(on database: any Database) async throws -> Set<String> {
        let activeRows = try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.ready.rawValue)
            .all()

        let warmingRows = try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.warming.rawValue)
            .all()

        let rows = activeRows + warmingRows
        return Set(rows.compactMap { row in
            guard let localPath = row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !localPath.isEmpty else {
                return nil
            }

            let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
            return canonicalPath(for: localURL.resolvingSymlinksInPath())
        })
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

    func isPathCurrentlyProtected(
        _ path: String,
        on database: any Database
    ) async throws -> Bool {
        let currentProtectedPaths = try await loadProtectedPaths(on: database)
        return currentProtectedPaths.contains(path)
    }

    func cleanupClaimLostMetadata(for row: PressureArtifactCatalogModel) -> Logger.Metadata {
        [
            "runTime": .string(row.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(row.forecastHour),
            "path": .string(row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil")
        ]
    }

    func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func isProtectedPath(_ path: String, protectedPaths: Set<String>) -> Bool {
        protectedPaths.contains(path)
    }
}
