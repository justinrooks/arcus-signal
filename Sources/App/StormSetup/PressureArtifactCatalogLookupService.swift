import Fluent
import Foundation

struct PressureArtifactCatalogReadyArtifact: Sendable, Equatable {
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let product: HrrrProduct
    let fieldSetVersion: HrrrFieldSetVersion
    let localFileURL: URL
    let byteSize: Int64
}

protocol PressureArtifactCatalogLookupProviding: Sendable {
    func readyArtifact(
        for candidate: HrrrRunCandidate
    ) async throws -> PressureArtifactCatalogReadyArtifact?
}

struct DefaultPressureArtifactCatalogLookupService: PressureArtifactCatalogLookupProviding, @unchecked Sendable {
    private let database: any Database
    private let fileManager: FileManager

    init(
        database: any Database,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.fileManager = fileManager
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
            byteSize: fileSize.int64Value
        )
    }
}
