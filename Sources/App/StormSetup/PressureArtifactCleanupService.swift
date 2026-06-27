import Fluent
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

    init(
        dateProvider: any StormSetupDateProviding,
        fileManager: FileManager = .default,
        cacheRootURL: URL,
        maxStaleAgeSeconds: TimeInterval,
        deleteGraceSeconds: TimeInterval
    ) {
        self.dateProvider = dateProvider
        self.fileManager = fileManager
        self.cacheRootURL = cacheRootURL
        self.maxStaleAgeSeconds = max(0, maxStaleAgeSeconds)
        self.deleteGraceSeconds = max(0, deleteGraceSeconds)
    }

    static func makeDefault(application: Application) -> PressureArtifactCleanupService {
        PressureArtifactCleanupService(
            dateProvider: SystemStormSetupDateProvider(),
            cacheRootURL: application.stormSetupConfiguration.pressureGribSubsetCacheRootURL,
            maxStaleAgeSeconds: application.stormSetupConfiguration.pressureArtifactMaxStaleAgeSeconds,
            deleteGraceSeconds: application.stormSetupConfiguration.pressureArtifactDeleteGraceSeconds
        )
    }

    func cleanup(on application: Application, logger: Logger) async throws {
        let now = dateProvider.now()
        let expirationCutoff = now.addingTimeInterval(-maxStaleAgeSeconds)
        let deletionCutoff = now.addingTimeInterval(-deleteGraceSeconds)

        let expiredRowsBeforeExpiration = try await loadExpiredRows(on: application.db)
        try await expireReadyArtifacts(before: expirationCutoff, on: application.db, logger: logger)
        let protectedPaths = try await loadProtectedPaths(on: application.db)
        try await deleteExpiredArtifacts(
            rows: expiredRowsBeforeExpiration,
            olderThan: deletionCutoff,
            protectedPaths: protectedPaths,
            on: application.db,
            logger: logger
        )
    }
}

private extension PressureArtifactCleanupService {
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

            guard let refreshed = try await PressureArtifactCatalogModel.find(row.id, on: database),
                  refreshed.status == PressureArtifactCatalogStatus.expired else {
                continue
            }

            guard let localPath = refreshed.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !localPath.isEmpty else {
                if refreshed.byteSize != nil {
                    refreshed.byteSize = nil
                    refreshed.errorSummary = nil
                    try await refreshed.save(on: database)
                }
                continue
            }

            let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
            let fileExists = fileManager.fileExists(atPath: localURL.path)

            guard fileExists else {
                guard localURL.path == canonicalRootPath || localURL.path.hasPrefix(canonicalRootPrefix) else {
                    try await recordUnsafePath(
                        refreshed,
                        reason: "cleanup path outside cache root",
                        on: database
                    )
                    logger.warning(
                        "Pressure artifact cleanup refused missing path outside cache root.",
                        metadata: [
                            "path": .string(localURL.path),
                            "runTime": .string(refreshed.runTime.ISO8601Format()),
                            "forecastHour": .stringConvertible(refreshed.forecastHour)
                        ]
                    )
                    continue
                }

                try await clearArtifactMetadata(refreshed, on: database)
                logger.info(
                    "Pressure artifact cleanup cleared missing file metadata.",
                    metadata: [
                        "path": .string(localURL.path),
                        "runTime": .string(refreshed.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(refreshed.forecastHour)
                    ]
                )
                continue
            }

            let resolvedURL = localURL.resolvingSymlinksInPath()
            let canonicalPath = canonicalPath(for: resolvedURL)

            guard canonicalPath == canonicalRootPath || canonicalPath.hasPrefix(canonicalRootPrefix) else {
                try await recordUnsafePath(
                    refreshed,
                    reason: "cleanup path outside cache root",
                    on: database
                )
                logger.warning(
                    "Pressure artifact cleanup refused unsafe path.",
                    metadata: [
                        "path": .string(canonicalPath),
                        "runTime": .string(refreshed.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(refreshed.forecastHour)
                    ]
                )
                continue
            }

            guard !isProtectedPath(canonicalPath, protectedPaths: protectedPaths) else {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                try await recordUnsafePath(
                    refreshed,
                    reason: "cleanup path is not a regular file",
                    on: database
                )
                logger.warning(
                    "Pressure artifact cleanup refused non-regular path.",
                    metadata: [
                        "path": .string(canonicalPath),
                        "runTime": .string(refreshed.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(refreshed.forecastHour)
                    ]
                )
                continue
            }

            do {
                try fileManager.removeItem(at: resolvedURL)
                try await clearArtifactMetadata(refreshed, on: database)
                logger.info(
                    "Pressure artifact deleted from cache.",
                    metadata: [
                        "path": .string(canonicalPath),
                        "runTime": .string(refreshed.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(refreshed.forecastHour)
                    ]
                )
            } catch {
                try await recordUnsafePath(
                    refreshed,
                    reason: "cleanup delete failed: \(String(describing: error))",
                    on: database
                )
                logger.error(
                    "Pressure artifact cleanup failed to delete file.",
                    metadata: [
                        "path": .string(canonicalPath),
                        "runTime": .string(refreshed.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(refreshed.forecastHour),
                        "error": .string(String(reflecting: error))
                    ]
                )
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

    func clearArtifactMetadata(
        _ row: PressureArtifactCatalogModel,
        on database: any Database
    ) async throws {
        row.localPath = nil
        row.byteSize = nil
        row.errorSummary = nil
        try await row.save(on: database)
    }

    func recordUnsafePath(
        _ row: PressureArtifactCatalogModel,
        reason: String,
        on database: any Database
    ) async throws {
        row.errorSummary = reason
        try await row.save(on: database)
    }

    func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    func isProtectedPath(_ path: String, protectedPaths: Set<String>) -> Bool {
        protectedPaths.contains(path)
    }
}
