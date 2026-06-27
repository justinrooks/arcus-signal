import Fluent
import Foundation

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
    private let fileManager: FileManager
    private let maximumStaleAgeSeconds: TimeInterval

    init(
        database: any Database,
        fileManager: FileManager = .default,
        maximumStaleAgeSeconds: TimeInterval = 2 * 60 * 60
    ) {
        self.database = database
        self.fileManager = fileManager
        self.maximumStaleAgeSeconds = maximumStaleAgeSeconds
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
            return nil
        }

        guard row.status == .ready else {
            return nil
        }

        return makeReadyArtifact(from: row, freshness: .exact)
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

            if let artifact = makeReadyArtifact(
                from: row,
                freshness: .stale(ageSeconds: ageSeconds)
            ) {
                return artifact
            }
        }

        return nil
    }

    private func makeReadyArtifact(
        from row: PressureArtifactCatalogModel,
        freshness: PressureArtifactCatalogReadyArtifactFreshness
    ) -> PressureArtifactCatalogReadyArtifact? {
        guard let localPath = row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localPath.isEmpty else {
            return nil
        }

        let localFileURL = URL(fileURLWithPath: localPath)
        guard let fileAttributes = try? fileManager.attributesOfItem(atPath: localFileURL.path),
              let fileType = fileAttributes[.type] as? FileAttributeType,
              fileType == .typeRegular,
              let fileSize = fileAttributes[.size] as? NSNumber,
              fileSize.int64Value > 0 else {
            return nil
        }

        return PressureArtifactCatalogReadyArtifact(
            runTime: row.runTime,
            forecastHour: row.forecastHour,
            validTime: row.validTime,
            product: row.product,
            fieldSetVersion: row.fieldSetVersion,
            localFileURL: localFileURL,
            byteSize: fileSize.int64Value,
            freshness: freshness
        )
    }
}
