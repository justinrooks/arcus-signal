import Fluent
import Foundation
import Vapor

protocol PressureArtifactCleaning: Sendable {
    func cleanup(on application: Application, logger: Logger) async throws
}

struct PressureArtifactCleanupService: PressureArtifactCleaning, @unchecked Sendable {
    private let dateProvider: any StormSetupDateProviding
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let fileManager: FileManager
    private let cacheRootURL: URL
    private let maxStaleAgeSeconds: TimeInterval
    private let deleteGraceSeconds: TimeInterval
    private let recoveryTimeoutSeconds: TimeInterval
    private let beforePhysicalRemovalHook: @Sendable () async -> Void
    private let catalogStore: PressureArtifactCatalogStore

    init(
        dateProvider: any StormSetupDateProviding,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        fileManager: FileManager = .default,
        cacheRootURL: URL,
        maxStaleAgeSeconds: TimeInterval,
        deleteGraceSeconds: TimeInterval,
        recoveryTimeoutSeconds: TimeInterval,
        beforePhysicalRemovalHook: @escaping @Sendable () async -> Void = {},
        catalogStore: PressureArtifactCatalogStore = PressureArtifactCatalogStore()
    ) {
        self.dateProvider = dateProvider
        self.blockingWorkExecutor = blockingWorkExecutor
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
        self.maxStaleAgeSeconds = max(0, maxStaleAgeSeconds)
        self.deleteGraceSeconds = max(0, deleteGraceSeconds)
        self.recoveryTimeoutSeconds = max(1, recoveryTimeoutSeconds)
        self.beforePhysicalRemovalHook = beforePhysicalRemovalHook
        self.catalogStore = catalogStore
    }

    static func makeDefault(application: Application) -> PressureArtifactCleanupService {
        PressureArtifactCleanupService(
            dateProvider: SystemStormSetupDateProvider(),
            blockingWorkExecutor: NIOThreadPoolPressureArtifactBlockingWorkExecutor(
                threadPool: application.threadPool
            ),
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
        let expiredCount = try await catalogStore.expireReadyArtifacts(
            before: expirationCutoff,
            on: application.db
        )
        if expiredCount > 0 {
            logger.info(
                "Pressure artifact cleanup expired ready rows.",
                metadata: ["count": .stringConvertible(expiredCount)]
            )
        }
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
    func deleteExpiredArtifacts(
        rows expiredRows: [PressureArtifactCatalogModel],
        olderThan cutoff: Date,
        cleanupLeaseExpiresAt: Date,
        protectedPaths: Set<String>,
        on database: any Database,
        logger: Logger
    ) async throws {
        let canonicalRootPath = try await canonicalPath(for: cacheRootURL)
        let canonicalRootPrefix = canonicalRootPath.hasSuffix("/") ? canonicalRootPath : canonicalRootPath + "/"

        for row in expiredRows {
            guard let updatedAt = row.updatedAt, updatedAt <= cutoff else {
                continue
            }

            guard let claimedRow = try await catalogStore.claimDeletionCandidate(
                for: row,
                olderThan: cutoff,
                cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
                on: database
            ) else {
                continue
            }

            guard let localPath = claimedRow.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !localPath.isEmpty else {
                if try await catalogStore.completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
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

            let localURL = try await standardizedFileURL(for: localPath)
            let fileExists = try await fileExists(at: localURL)

            guard fileExists else {
                guard localURL.path == canonicalRootPath || localURL.path.hasPrefix(canonicalRootPrefix) else {
                    if try await catalogStore.completeFailedCleanup(
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

                if try await catalogStore.completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
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

            let resolvedURL = try await resolvedURL(for: localURL)
            let canonicalPath = try await canonicalPath(for: resolvedURL)

            guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalRootPrefix) else {
                if try await catalogStore.completeFailedCleanup(
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
                if try await catalogStore.releaseCleanupClaim(
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
                if try await catalogStore.releaseCleanupClaim(
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

            guard try await isRegularFile(at: resolvedURL) else {
                if try await catalogStore.completeFailedCleanup(
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

            guard try await catalogStore.ownsCleanupClaim(for: claimedRow, claimToken: claimedRow.claimToken, on: database) else {
                logger.info(
                    "Pressure artifact cleanup lost claim ownership.",
                    metadata: cleanupClaimLostMetadata(for: claimedRow)
                )
                continue
            }

            do {
                try await removeItem(at: resolvedURL)
                if try await catalogStore.completeSuccessfulCleanup(for: claimedRow, claimToken: claimedRow.claimToken, on: database) {
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
                if try await catalogStore.completeFailedCleanup(
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
        var protectedPaths = Set<String>()
        protectedPaths.reserveCapacity(rows.count)

        for row in rows {
            guard let localPath = row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !localPath.isEmpty else {
                continue
            }

            let localURL = try await standardizedFileURL(for: localPath)
            let canonicalPath = try await canonicalPath(for: localURL)
            protectedPaths.insert(canonicalPath)
        }

        return protectedPaths
    }

    func isPathCurrentlyProtected(
        _ path: String,
        on database: any Database
    ) async throws -> Bool {
        let currentProtectedPaths = try await loadProtectedPaths(on: database)
        return currentProtectedPaths.contains(path)
    }

    func standardizedFileURL(for localPath: String) async throws -> URL {
        let localPath = localPath
        return try await blockingWorkExecutor.execute {
            URL(fileURLWithPath: localPath).standardizedFileURL
        }
    }

    func resolvedURL(for localURL: URL) async throws -> URL {
        let localURL = localURL
        return try await blockingWorkExecutor.execute {
            localURL.resolvingSymlinksInPath()
        }
    }

    func canonicalPath(for url: URL) async throws -> String {
        let url = url
        return try await blockingWorkExecutor.execute {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
    }

    func fileExists(at url: URL) async throws -> Bool {
        let url = url
        return try await blockingWorkExecutor.execute {
            fileManager.fileExists(atPath: url.path)
        }
    }

    func isRegularFile(at url: URL) async throws -> Bool {
        let url = url
        return try await blockingWorkExecutor.execute {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && !isDirectory.boolValue
        }
    }

    func removeItem(at url: URL) async throws {
        let url = url
        try await blockingWorkExecutor.execute {
            try fileManager.removeItem(at: url)
        }
    }

    func cleanupClaimLostMetadata(for row: PressureArtifactCatalogModel) -> Logger.Metadata {
        [
            "runTime": .string(row.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(row.forecastHour),
            "path": .string(row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "nil")
        ]
    }

    func isProtectedPath(_ path: String, protectedPaths: Set<String>) -> Bool {
        protectedPaths.contains(path)
    }
}
