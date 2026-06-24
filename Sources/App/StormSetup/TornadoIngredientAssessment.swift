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

    func lowered() -> IngredientSupport {
        switch self {
        case .unknown:
            return .unknown
        case .weak:
            return .weak
        case .conditional:
            return .weak
        case .supportive:
            return .conditional
        case .strong:
            return .supportive
        }
    }

    func raised() -> IngredientSupport {
        switch self {
        case .unknown:
            return .unknown
        case .weak:
            return .conditional
        case .conditional:
            return .supportive
        case .supportive:
            return .strong
        case .strong:
            return .strong
        }
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

extension SnapshotConfidence {
    func lowered() -> SnapshotConfidence {
        switch self {
        case .high:
            return .moderate
        case .moderate:
            return .low
        case .low:
            return .degraded
        case .degraded:
            return .degraded
        }
    }

    func raised() -> SnapshotConfidence {
        switch self {
        case .degraded:
            return .low
        case .low:
            return .moderate
        case .moderate:
            return .high
        case .high:
            return .high
        }
    }
}
