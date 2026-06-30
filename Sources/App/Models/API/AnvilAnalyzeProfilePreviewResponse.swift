import Foundation
import Vapor

struct AnvilAnalyzeProfilePreviewResponse: Content, Sendable, Equatable {
    let request: AnvilAnalyzeProfileRequest
    let debug: AnvilAnalyzeProfilePreviewDebugDTO
}

struct AnvilAnalyzeProfilePreviewDebugDTO: Content, Sendable, Equatable {
    let sourceKind: HrrrSourceKind
    let product: HrrrProduct
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let h3: String
    let centroid: StormSetupCentroid
    let selectedMessageCount: Int
    let selectedPressureLevels: [Int]
    let rangeCount: Int
    let totalSelectedRangeBytes: Int64
    let pressureLevelsRequested: [Int]
    let pressureLevelsRetained: [Int]
    let missingLevels: [AnvilAnalyzeProfilePreviewMissingLevelDTO]
    let warnings: [String]
    let subsetCacheHit: Bool
    let primaryDownloadURL: URL?
    let idxURL: URL?
    let idxAvailable: Bool?
    let gribAvailable: Bool?
}

struct AnvilAnalyzeProfilePreviewMissingLevelDTO: Content, Sendable, Equatable {
    let pressureMb: Int
    let missingVariables: [StormSetupPressureProfileVariable]
}
