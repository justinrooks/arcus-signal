import Foundation
import Vapor

struct TornadoIngredientAssessment: Content, Sendable {
    let overall: IngredientSupport
    let instability: IngredientSupport
    let moisture: IngredientSupport
    let cloudBase: IngredientSupport
    let capInhibition: IngredientSupport
    let deepShear: IngredientSupport
    let lowLevelRotation: IngredientSupport
    let stormMode: IngredientSupport
    let compositeSignal: IngredientSupport
    let confidence: SnapshotConfidence
    let trend: IngredientTrend
    let stormModeHint: StormModeHint
    let primaryDrivers: [String]
    let limitingFactors: [TornadoLimitingFactor]
    let summary: String
}

enum IngredientSupport: String, Content, Sendable, Hashable, Comparable {
    case weak
    case conditional
    case supportive
    case strong
    case unknown
}

enum SnapshotConfidence: String, Content, Sendable, Hashable {
    case low
    case moderate
    case high
    case degraded
}

enum IngredientTrend: String, Content, Sendable, Hashable {
    case increasing
    case steady
    case decreasing
    case unknown
}

enum StormModeHint: String, Content, Sendable, Hashable {
    case discreteSupercells
    case mixedMode
    case linear
    case clustered
    case elevated
    case unknown
}

enum TornadoLimitingFactor: String, Content, Sendable, Hashable {
    case weakInstability
    case weakDeepShear
    case weakLowLevelRotation
    case elevatedCloudBases
    case strongCap
    case weakLift
    case messyStormMode
    case poorMoisture
    case unknown
}

extension IngredientSupport {
    static func < (lhs: IngredientSupport, rhs: IngredientSupport) -> Bool {
        lhs.comparisonRank < rhs.comparisonRank
    }

    var comparisonRank: Int {
        switch self {
        case .unknown:
            return -1
        case .weak:
            return 0
        case .conditional:
            return 1
        case .supportive:
            return 2
        case .strong:
            return 3
        }
    }
}
