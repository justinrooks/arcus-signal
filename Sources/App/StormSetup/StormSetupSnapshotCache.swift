import Foundation

struct StormSetupSnapshotCacheResult: Sendable {
    let snapshot: TornadoIngredientSnapshot
    let cacheHit: Bool
    let fetchedAt: Date
    let expiresAt: Date
    let sourceValidTime: Date?
    let rulesVersion: StormSetupRulesVersion
}

struct StormSetupSnapshotCacheRecord: Codable, Sendable {
    let key: StormSetupSnapshotCacheKey
    let snapshot: TornadoIngredientSnapshot
}

enum StormSetupSnapshotCacheError: Error, Sendable, CustomStringConvertible {
    case mismatchedSnapshotKey(expected: StormSetupSnapshotCacheKey, actual: StormSetupSnapshotCacheKey)
    case unableToCreateDirectory(path: URL, reason: String)
    case unableToWriteCache(path: URL, reason: String)

    var description: String {
        switch self {
        case .mismatchedSnapshotKey(let expected, let actual):
            return "Storm Setup snapshot cache key mismatch. Expected \(expected.cacheIdentifier), got \(actual.cacheIdentifier)."
        case .unableToCreateDirectory(let path, let reason):
            return "Unable to create Storm Setup snapshot cache directory at \(path.path): \(reason)"
        case .unableToWriteCache(let path, let reason):
            return "Unable to write Storm Setup snapshot cache at \(path.path): \(reason)"
        }
    }
}

actor StormSetupSnapshotCache {
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let filesystemCriticalSection = BlockingWorkCriticalSection()
    private let rootURL: URL
    private let dateProvider: any StormSetupDateProviding

    init(
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        rootURL: URL = StormSetupConfiguration.localSampledSnapshotCacheRootURL,
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider()
    ) {
        self.blockingWorkExecutor = blockingWorkExecutor
        self.rootURL = rootURL
        self.dateProvider = dateProvider
    }

    func loadSnapshot(for key: StormSetupSnapshotCacheKey) async -> StormSetupSnapshotCacheResult? {
        let fileURL = key.snapshotFileURL(rootURL: rootURL)
        let now = dateProvider.now()

        do {
            return try await executeFilesystemWork {
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    return nil
                }

                do {
                    let data = try Data(contentsOf: fileURL)
                    let jsonDecoder = Self.makeJSONDecoder()
                    let record = try jsonDecoder.decode(StormSetupSnapshotCacheRecord.self, from: data)

                    guard record.key == key else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return nil
                    }

                    guard let derivedKey = try? StormSetupSnapshotCacheKey(
                        h3Cell: record.snapshot.h3Cell,
                        sourceMetadata: record.snapshot.source,
                        rulesVersion: key.rulesVersion
                    ), derivedKey == key else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return nil
                    }

                    let snapshot = record.snapshot.surfaceSnapshot(rulesVersion: key.rulesVersion)
                    let freshness = record.snapshot.freshness
                    guard freshness.sourceValidTime == key.validTime else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return nil
                    }
                    guard freshness.expiresAt > now else {
                        try? FileManager.default.removeItem(at: fileURL)
                        return nil
                    }

                    return StormSetupSnapshotCacheResult(
                        snapshot: snapshot,
                        cacheHit: true,
                        fetchedAt: freshness.fetchedAt,
                        expiresAt: freshness.expiresAt,
                        sourceValidTime: freshness.sourceValidTime,
                        rulesVersion: key.rulesVersion
                    )
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    return nil
                }
            }
        } catch {
            return nil
        }
    }

    func store(
        snapshot: TornadoIngredientSnapshot,
        for key: StormSetupSnapshotCacheKey
    ) async throws -> StormSetupSnapshotCacheResult {
        let fileURL = key.snapshotFileURL(rootURL: rootURL)
        let directoryURL = key.directoryURL(rootURL: rootURL)

        let actualKey = try StormSetupSnapshotCacheKey(
            h3Cell: snapshot.h3Cell,
            sourceMetadata: snapshot.source,
            rulesVersion: key.rulesVersion
        )
        guard actualKey == key else {
            throw StormSetupSnapshotCacheError.mismatchedSnapshotKey(expected: key, actual: actualKey)
        }

        guard snapshot.freshness.sourceValidTime == key.validTime else {
            throw StormSetupSnapshotCacheError.mismatchedSnapshotKey(expected: key, actual: actualKey)
        }

        return try await executeFilesystemWork {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            } catch {
                throw StormSetupSnapshotCacheError.unableToCreateDirectory(
                    path: directoryURL,
                    reason: String(describing: error)
                )
            }

            let surfaceSnapshot = snapshot.surfaceSnapshot(rulesVersion: key.rulesVersion)
            let record = StormSetupSnapshotCacheRecord(key: key, snapshot: surfaceSnapshot)
            let jsonEncoder = Self.makeJSONEncoder()
            let data = try jsonEncoder.encode(record)

            do {
                try data.write(to: fileURL, options: [.atomic])
            } catch {
                throw StormSetupSnapshotCacheError.unableToWriteCache(path: fileURL, reason: String(describing: error))
            }

            let freshness = snapshot.freshness
            return StormSetupSnapshotCacheResult(
                snapshot: surfaceSnapshot,
                cacheHit: false,
                fetchedAt: freshness.fetchedAt,
                expiresAt: freshness.expiresAt,
                sourceValidTime: freshness.sourceValidTime,
                rulesVersion: key.rulesVersion
            )
        }
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func executeFilesystemWork<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let filesystemCriticalSection = filesystemCriticalSection
        return try await blockingWorkExecutor.execute {
            try filesystemCriticalSection.withLock(operation)
        }
    }
}

private extension TornadoIngredientSnapshot {
    func surfaceSnapshot(rulesVersion: StormSetupRulesVersion) -> TornadoIngredientSnapshot {
        let baselineAssessment = TornadoIngredientInterpreter(rulesVersion: rulesVersion).assess(
            raw: raw,
            freshness: freshness
        )

        return TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: centroid,
            source: source,
            raw: raw,
            surfaceHeightMslM: surfaceHeightMslM,
            assessment: baselineAssessment,
            freshness: freshness
        )
    }
}
