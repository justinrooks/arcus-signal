import Foundation
import Vapor

struct TornadoIngredientSnapshot: Content, Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
    let source: StormSetupSourceMetadata
    let raw: TornadoRawParameters
    let assessment: TornadoIngredientAssessment
    let freshness: IngredientFreshness
}

struct StormSetupCentroid: Content, Sendable {
    let latitude: Double
    let longitude: Double
}

struct StormSetupSourceMetadata: Content, Sendable {
    let model: String?
    let runTime: Date?
    let forecastHour: Int?
    let validTime: Date?
}

struct TornadoRawParameters: Content, Sendable {
    let sbcapeJkg: Double?
    let mlcapeJkg: Double?
    let mucapeJkg: Double?
    let dcapeJkg: Double?
    let mllclM: Double?
    let temperatureDewpointSpreadF: Double?
    let lclLfcSeparationM: Double?
    let lapseRate03kmCkm: Double?
    let lapseRate700500mbCkm: Double?
    let shear06kmKt: Double?
    let shear03kmKt: Double?
    let shear01kmKt: Double?
    let effectiveShearKt: Double?
    let srh01kmM2s2: Double?
    let srh03kmM2s2: Double?
    let effectiveSrhM2s2: Double?
    let supercellComposite: Double?
    let significantTornadoFixed: Double?
    let significantTornadoEffective: Double?
    let significantHail: Double?
    let bunkersRightMotion: DirectionSpeed?
    let bunkersLeftMotion: DirectionSpeed?
    let stormRelativeWind46km: DirectionSpeed?
    let meanWind850300mb: DirectionSpeed?
}

struct DirectionSpeed: Content, Sendable {
    let directionDegrees: Double
    let speedKt: Double
}

struct TornadoIngredientAssessment: Content, Sendable {
    let overall: IngredientSupport?
    let instability: IngredientSupport?
    let moisture: IngredientSupport?
    let cloudBase: IngredientSupport?
    let capInhibition: IngredientSupport?
    let deepShear: IngredientSupport?
    let lowLevelRotation: IngredientSupport?
    let stormMode: IngredientSupport?
    let compositeSignal: IngredientSupport?
    let confidence: SnapshotConfidence?
    let trend: IngredientTrend?
    let stormModeHint: StormModeHint?
    let primaryDrivers: [String]?
    let limitingFactors: [TornadoLimitingFactor]?
    let summary: String?
}

enum IngredientSupport: String, Content, Sendable {
    case weak
    case conditional
    case supportive
    case strong
    case unknown
}

enum SnapshotConfidence: String, Content, Sendable {
    case low
    case moderate
    case high
    case degraded
}

enum IngredientTrend: String, Content, Sendable {
    case increasing
    case steady
    case decreasing
    case unknown
}

enum StormModeHint: String, Content, Sendable {
    case discreteSupercells
    case mixedMode
    case linear
    case clustered
    case elevated
    case unknown
}

enum TornadoLimitingFactor: String, Content, Sendable {
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

struct IngredientFreshness: Content, Sendable {
    let sourceValidTime: Date?
    let modelRunTime: Date?
    let forecastHour: Int?
    let fetchedAt: Date
    let expiresAt: Date?
    let isStale: Bool
}

struct StormSetupResolvedH3Cell: Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
}
