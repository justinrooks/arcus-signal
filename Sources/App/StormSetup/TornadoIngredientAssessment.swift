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
    let lowLevelRotationSupport: IngredientSupport?
    let lowLevelStretching: IngredientSupport?
    let cloudBaseEfficiency: IngredientSupport?
    let tornadoEfficiency: IngredientSupport?
    let stormViability: IngredientSupport?
    let supercellViability: IngredientSupport?
    let supercellComposite: IngredientSupport?
    let stormMode: IngredientSupport
    let compositeSignal: IngredientSupport
    let realization: TornadoViabilityRealization?
    let primaryFailureMode: TornadoViabilityFailureMode?
    let viabilityLimiters: [TornadoViabilityLimiter]?
    let confidence: SnapshotConfidence
    let trend: IngredientTrend
    let stormModeHint: StormModeHint
    let primaryDrivers: [String]
    let limitingFactors: [TornadoLimitingFactor]
    let summary: String

    init(
        overall: IngredientSupport,
        instability: IngredientSupport,
        moisture: IngredientSupport,
        cloudBase: IngredientSupport,
        capInhibition: IngredientSupport,
        deepShear: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        stormMode: IngredientSupport,
        compositeSignal: IngredientSupport,
        confidence: SnapshotConfidence,
        trend: IngredientTrend,
        stormModeHint: StormModeHint,
        primaryDrivers: [String],
        limitingFactors: [TornadoLimitingFactor],
        summary: String,
        lowLevelRotationSupport: IngredientSupport? = nil,
        lowLevelStretching: IngredientSupport? = nil,
        cloudBaseEfficiency: IngredientSupport? = nil,
        tornadoEfficiency: IngredientSupport? = nil,
        stormViability: IngredientSupport? = nil,
        supercellViability: IngredientSupport? = nil,
        supercellComposite: IngredientSupport? = nil,
        realization: TornadoViabilityRealization? = nil,
        primaryFailureMode: TornadoViabilityFailureMode? = nil,
        viabilityLimiters: [TornadoViabilityLimiter]? = nil
    ) {
        self.overall = overall
        self.instability = instability
        self.moisture = moisture
        self.cloudBase = cloudBase
        self.capInhibition = capInhibition
        self.deepShear = deepShear
        self.lowLevelRotation = lowLevelRotation
        self.lowLevelRotationSupport = lowLevelRotationSupport
        self.lowLevelStretching = lowLevelStretching
        self.cloudBaseEfficiency = cloudBaseEfficiency
        self.tornadoEfficiency = tornadoEfficiency
        self.stormViability = stormViability
        self.supercellViability = supercellViability
        self.supercellComposite = supercellComposite
        self.stormMode = stormMode
        self.compositeSignal = compositeSignal
        self.realization = realization
        self.primaryFailureMode = primaryFailureMode
        self.viabilityLimiters = viabilityLimiters
        self.confidence = confidence
        self.trend = trend
        self.stormModeHint = stormModeHint
        self.primaryDrivers = primaryDrivers
        self.limitingFactors = limitingFactors
        self.summary = summary
    }
}

extension TornadoIngredientAssessment {
    func adjusted(
        confidence: SnapshotConfidence? = nil,
        summary: String? = nil
    ) -> TornadoIngredientAssessment {
        TornadoIngredientAssessment(
            overall: overall,
            instability: instability,
            moisture: moisture,
            cloudBase: cloudBase,
            capInhibition: capInhibition,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
            stormMode: stormMode,
            compositeSignal: compositeSignal,
            confidence: confidence ?? self.confidence,
            trend: trend,
            stormModeHint: stormModeHint,
            primaryDrivers: primaryDrivers,
            limitingFactors: limitingFactors,
            summary: summary ?? self.summary,
            lowLevelRotationSupport: lowLevelRotationSupport,
            lowLevelStretching: lowLevelStretching,
            cloudBaseEfficiency: cloudBaseEfficiency,
            tornadoEfficiency: tornadoEfficiency,
            stormViability: stormViability,
            supercellViability: supercellViability,
            supercellComposite: supercellComposite,
            realization: realization,
            primaryFailureMode: primaryFailureMode,
            viabilityLimiters: viabilityLimiters
        )
    }
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

enum TornadoViabilityLimiter: String, Content, Sendable, Hashable {
    case weakInstability
    case weakDeepShear
    case weakLowLevelRotation
    case weakLowLevelStretching
    case elevatedCloudBases
    case strongCap
    case conditionalInitiation
    case weakStormOrganization
    case fixedEffectiveStpDisagreement
    case poorMoisture
    case missingStormMode
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
