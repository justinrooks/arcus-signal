import Fluent
import Foundation
import Logging

enum PressureArtifactCatalogReadyArtifactFreshness: Sendable, Equatable {
    case exact
    case stale(ageSeconds: TimeInterval)
}

struct PressureArtifactCatalogReadyArtifact: Sendable, Equatable {
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let product: HrrrProduct
    let fieldSetVersion: HrrrFieldSetVersion
    let localFileURL: URL
    let byteSize: Int64
    let freshness: PressureArtifactCatalogReadyArtifactFreshness

    init(
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion,
        localFileURL: URL,
        byteSize: Int64,
        freshness: PressureArtifactCatalogReadyArtifactFreshness = .exact
    ) {
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.product = product
        self.fieldSetVersion = fieldSetVersion
        self.localFileURL = localFileURL
        self.byteSize = byteSize
        self.freshness = freshness
    }
}

protocol PressureArtifactCatalogLookupProviding: Sendable {
    func readyArtifact(
        for candidate: HrrrRunCandidate
    ) async throws -> PressureArtifactCatalogReadyArtifact?

    func staleArtifact(
        for resolution: HrrrRunResolution
    ) async throws -> PressureArtifactCatalogReadyArtifact?
}

struct DefaultPressureArtifactCatalogLookupService: PressureArtifactCatalogLookupProviding, @unchecked Sendable {
    private let database: any Database
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let maximumStaleAgeSeconds: TimeInterval
    private let logger: Logger

    init(
        database: any Database,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        maximumStaleAgeSeconds: TimeInterval = 2 * 60 * 60,
        logger: Logger = Logger(label: "pressure-artifact-catalog-lookup")
    ) {
        self.database = database
        self.blockingWorkExecutor = blockingWorkExecutor
        self.maximumStaleAgeSeconds = maximumStaleAgeSeconds
        self.logger = logger
    }

    func readyArtifact(
        for candidate: HrrrRunCandidate
    ) async throws -> PressureArtifactCatalogReadyArtifact? {
        guard let row = try await PressureArtifactCatalogModel.find(
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            product: candidate.product,
            fieldSetVersion: candidate.fieldSetVersion,
            on: database
        ) else {
            logger.info(
                "Pressure artifact exact lookup missed.",
                metadata: candidateMetadata(for: candidate, reason: "catalogRowMissing")
            )
            return nil
        }

        guard row.status == .ready else {
            logger.info(
                "Pressure artifact exact lookup skipped non-ready row.",
                metadata: rowMetadata(
                    row,
                    freshnessOutcome: "exact",
                    reason: "catalogStatusNotReady"
                )
            )
            return nil
        }

        guard let artifact = try await makeReadyArtifact(from: row, freshness: .exact) else {
            logger.info(
                "Pressure artifact exact lookup found unusable local file.",
                metadata: rowMetadata(
                    row,
                    freshnessOutcome: "exact",
                    reason: "localFileUnusable"
                )
            )
            return nil
        }

        logger.info(
            "Pressure artifact exact lookup hit.",
            metadata: artifactMetadata(
                artifact: artifact,
                freshnessOutcome: "exact",
                source: row.sourceRaw
            )
        )
        return artifact
    }

    func staleArtifact(
        for resolution: HrrrRunResolution
    ) async throws -> PressureArtifactCatalogReadyArtifact? {
        guard let pressureCandidate = resolution.candidates.first else {
            return nil
        }

        let minimumValidTime = resolution.targetValidTime.addingTimeInterval(-maximumStaleAgeSeconds)

        let candidateRows = try await PressureArtifactCatalogModel.query(on: database)
            .filter(\.$productRaw == pressureCandidate.product.rawValue)
            .filter(\.$fieldSetVersionRaw == pressureCandidate.fieldSetVersion.rawValue)
            .filter(\.$statusRaw == PressureArtifactCatalogStatus.ready.rawValue)
            .sort(\.$validTime, .descending)
            .all()

        for row in candidateRows {
            guard row.validTime >= minimumValidTime, row.validTime < resolution.targetValidTime else {
                continue
            }

            let ageSeconds = resolution.targetValidTime.timeIntervalSince(row.validTime)

            guard let artifact = try await makeReadyArtifact(
                from: row,
                freshness: .stale(ageSeconds: ageSeconds)
            ) else {
                logger.info(
                    "Pressure artifact stale candidate skipped because its file is unusable.",
                    metadata: rowMetadata(
                        row,
                        freshnessOutcome: "stale",
                        staleAgeSeconds: ageSeconds,
                        reason: "localFileUnusable"
                    )
                )
                continue
            }

            logger.info(
                "Pressure artifact stale lookup hit.",
                metadata: artifactMetadata(
                    artifact: artifact,
                    freshnessOutcome: "stale",
                    staleAgeSeconds: ageSeconds,
                    source: row.sourceRaw
                )
            )
            return artifact
        }

        logger.info(
            "Pressure artifact stale lookup missed.",
            metadata: candidateMetadata(
                for: pressureCandidate,
                reason: "noEligibleStaleArtifact"
            )
        )
        return nil
    }

    private func makeReadyArtifact(
        from row: PressureArtifactCatalogModel,
        freshness: PressureArtifactCatalogReadyArtifactFreshness
    ) async throws -> PressureArtifactCatalogReadyArtifact? {
        guard let localPath = row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localPath.isEmpty else {
            return nil
        }

        let localFileURL = URL(fileURLWithPath: localPath)
        let fileInfo: FileInfo?
        do {
            fileInfo = try await blockingWorkExecutor.execute {
                try Self.inspectRegularFile(at: localFileURL)
            }
        } catch {
            return nil
        }

        guard let fileInfo else {
            return nil
        }

        return PressureArtifactCatalogReadyArtifact(
            runTime: row.runTime,
            forecastHour: row.forecastHour,
            validTime: row.validTime,
            product: row.product,
            fieldSetVersion: row.fieldSetVersion,
            localFileURL: localFileURL,
            byteSize: fileInfo.byteSize,
            freshness: freshness
        )
    }

    private struct FileInfo: Sendable {
        let byteSize: Int64
    }

    private static func inspectRegularFile(
        at localFileURL: URL
    ) throws -> FileInfo? {
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: localFileURL.path)
        guard let fileType = fileAttributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = fileAttributes[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return nil
        }

        return FileInfo(byteSize: fileSize.int64Value)
    }

    func candidateMetadata(
        for candidate: HrrrRunCandidate,
        reason: String
    ) -> Logger.Metadata {
        [
            "runTime": .string(candidate.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(candidate.forecastHour),
            "validTime": .string(candidate.validTime.ISO8601Format()),
            "product": .string(candidate.product.rawValue),
            "fieldSetVersion": .string(candidate.fieldSetVersion.rawValue),
            "catalogSkipReason": .string(reason)
        ]
    }

    func rowMetadata(
        _ row: PressureArtifactCatalogModel,
        freshnessOutcome: String,
        staleAgeSeconds: TimeInterval? = nil,
        reason: String? = nil
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "runTime": .string(row.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(row.forecastHour),
            "validTime": .string(row.validTime.ISO8601Format()),
            "product": .string(row.product.rawValue),
            "fieldSetVersion": .string(row.fieldSetVersion.rawValue),
            "status": .string(row.statusRaw),
            "source": .string(row.sourceRaw),
            "byteSize": .stringConvertible(row.byteSize ?? 0),
            "freshnessOutcome": .string(freshnessOutcome)
        ]

        if let staleAgeSeconds {
            metadata["staleAgeSeconds"] = .stringConvertible(Int(staleAgeSeconds.rounded()))
        }

        if let reason {
            metadata["catalogSkipReason"] = .string(reason)
        }

        return metadata
    }

    func artifactMetadata(
        artifact: PressureArtifactCatalogReadyArtifact,
        freshnessOutcome: String,
        staleAgeSeconds: TimeInterval? = nil,
        source: String
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "runTime": .string(artifact.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(artifact.forecastHour),
            "validTime": .string(artifact.validTime.ISO8601Format()),
            "product": .string(artifact.product.rawValue),
            "fieldSetVersion": .string(artifact.fieldSetVersion.rawValue),
            "byteSize": .stringConvertible(artifact.byteSize),
            "freshnessOutcome": .string(freshnessOutcome),
            "source": .string(source)
        ]

        if let staleAgeSeconds {
            metadata["staleAgeSeconds"] = .stringConvertible(Int(staleAgeSeconds.rounded()))
        }

        return metadata
    }
}
