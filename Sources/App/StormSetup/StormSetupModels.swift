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
    let model: HrrrModel?
    let product: HrrrProduct?
    let domain: HrrrDomain?
    let runTime: Date?
    let forecastHour: Int?
    let validTime: Date?
    let fieldSetVersion: HrrrFieldSetVersion?
    let bbox: StormSetupHrrrBoundingBox?
    let nomadsURL: URL?
}

struct TornadoRawParameters: Content, Sendable {
    let sbcapeJkg: Double?
    let mlcapeJkg: Double?
    let mucapeJkg: Double?
    let mlcinJkg: Double?
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
    let diagnostics: [TornadoRawParameterDiagnostic]?
}

extension TornadoRawParameters {
    var nonNilFieldCount: Int {
        [
            sbcapeJkg != nil,
            mlcapeJkg != nil,
            mucapeJkg != nil,
            mlcinJkg != nil,
            dcapeJkg != nil,
            mllclM != nil,
            temperatureDewpointSpreadF != nil,
            lclLfcSeparationM != nil,
            lapseRate03kmCkm != nil,
            lapseRate700500mbCkm != nil,
            shear06kmKt != nil,
            shear03kmKt != nil,
            shear01kmKt != nil,
            effectiveShearKt != nil,
            srh01kmM2s2 != nil,
            srh03kmM2s2 != nil,
            effectiveSrhM2s2 != nil,
            supercellComposite != nil,
            significantTornadoFixed != nil,
            significantTornadoEffective != nil,
            significantHail != nil,
            bunkersRightMotion != nil,
            bunkersLeftMotion != nil,
            stormRelativeWind46km != nil,
            meanWind850300mb != nil
        ]
        .filter { $0 }
        .count
    }
}

struct DirectionSpeed: Content, Sendable {
    let directionDegrees: Double
    let speedKt: Double
}

enum TornadoRawParameterKey: String, Content, Sendable {
    case sbcapeJkg
    case mlcapeJkg
    case mucapeJkg
    case mlcinJkg
    case srh01kmM2s2
    case srh03kmM2s2
    case effectiveSrhM2s2
    case shear06kmKt
    case effectiveShearKt
    case mllclM
}

struct TornadoRawParameterDiagnostic: Content, Sendable {
    let inventory: String
    let parsedValue: Double?
    let matchedRawParameterKey: TornadoRawParameterKey?
    let requestedLongitude: Double
    let requestedLatitude: Double
    let nearestLongitude: Double?
    let nearestLatitude: Double?
}

struct StormSetupResolvedH3Cell: Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
}
