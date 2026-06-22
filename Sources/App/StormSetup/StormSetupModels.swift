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

struct StormSetupCentroid: Content, Sendable, Equatable {
    let latitude: Double
    let longitude: Double
}

struct StormSetupSourceMetadata: Content, Sendable {
    let sourceKind: HrrrSourceKind
    let model: HrrrModel?
    let product: HrrrProduct?
    let domain: HrrrDomain?
    let runTime: Date?
    let forecastHour: Int?
    let validTime: Date?
    let fieldSetVersion: HrrrFieldSetVersion?
    let bbox: StormSetupHrrrBoundingBox?
    let primaryDownloadURL: URL?
    let idxURL: URL?

    init(
        sourceKind: HrrrSourceKind = .nomadsFilteredSubset,
        model: HrrrModel?,
        product: HrrrProduct?,
        domain: HrrrDomain?,
        runTime: Date?,
        forecastHour: Int?,
        validTime: Date?,
        fieldSetVersion: HrrrFieldSetVersion?,
        bbox: StormSetupHrrrBoundingBox? = nil,
        primaryDownloadURL: URL? = nil,
        idxURL: URL? = nil
    ) {
        self.sourceKind = sourceKind
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.fieldSetVersion = fieldSetVersion
        self.bbox = bbox
        self.primaryDownloadURL = primaryDownloadURL
        self.idxURL = idxURL
    }

    init(
        model: HrrrModel?,
        product: HrrrProduct?,
        domain: HrrrDomain?,
        runTime: Date?,
        forecastHour: Int?,
        validTime: Date?,
        fieldSetVersion: HrrrFieldSetVersion?,
        bbox: StormSetupHrrrBoundingBox? = nil,
        nomadsURL: URL? = nil
    ) {
        self.init(
            sourceKind: .nomadsFilteredSubset,
            model: model,
            product: product,
            domain: domain,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            fieldSetVersion: fieldSetVersion,
            bbox: bbox,
            primaryDownloadURL: nomadsURL,
            idxURL: nil
        )
    }

    var nomadsURL: URL? {
        primaryDownloadURL
    }
}

struct TornadoRawParameters: Content, Sendable {
    let sbcapeJkg: Double?
    let mlcapeJkg: Double?
    let mucapeJkg: Double?
    let mlcinJkg: Double?
    let dcapeJkg: Double?
    let mllclM: Double?
    let tempDewPtDeltaF: Double?
    let threeCapeJkg: Double?
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

    init(
        sbcapeJkg: Double?,
        mlcapeJkg: Double?,
        mucapeJkg: Double?,
        mlcinJkg: Double?,
        dcapeJkg: Double?,
        mllclM: Double?,
        tempDewPtDeltaF: Double? = nil,
        threeCapeJkg: Double? = nil,
        temperatureDewpointSpreadF: Double?,
        lclLfcSeparationM: Double?,
        lapseRate03kmCkm: Double?,
        lapseRate700500mbCkm: Double?,
        shear06kmKt: Double?,
        shear03kmKt: Double?,
        shear01kmKt: Double?,
        effectiveShearKt: Double?,
        srh01kmM2s2: Double?,
        srh03kmM2s2: Double?,
        effectiveSrhM2s2: Double?,
        supercellComposite: Double?,
        significantTornadoFixed: Double?,
        significantTornadoEffective: Double?,
        significantHail: Double?,
        bunkersRightMotion: DirectionSpeed?,
        bunkersLeftMotion: DirectionSpeed?,
        stormRelativeWind46km: DirectionSpeed?,
        meanWind850300mb: DirectionSpeed?,
        diagnostics: [TornadoRawParameterDiagnostic]? = nil
    ) {
        self.sbcapeJkg = sbcapeJkg
        self.mlcapeJkg = mlcapeJkg
        self.mucapeJkg = mucapeJkg
        self.mlcinJkg = mlcinJkg
        self.dcapeJkg = dcapeJkg
        self.mllclM = mllclM
        self.tempDewPtDeltaF = tempDewPtDeltaF
        self.threeCapeJkg = threeCapeJkg
        self.temperatureDewpointSpreadF = temperatureDewpointSpreadF
        self.lclLfcSeparationM = lclLfcSeparationM
        self.lapseRate03kmCkm = lapseRate03kmCkm
        self.lapseRate700500mbCkm = lapseRate700500mbCkm
        self.shear06kmKt = shear06kmKt
        self.shear03kmKt = shear03kmKt
        self.shear01kmKt = shear01kmKt
        self.effectiveShearKt = effectiveShearKt
        self.srh01kmM2s2 = srh01kmM2s2
        self.srh03kmM2s2 = srh03kmM2s2
        self.effectiveSrhM2s2 = effectiveSrhM2s2
        self.supercellComposite = supercellComposite
        self.significantTornadoFixed = significantTornadoFixed
        self.significantTornadoEffective = significantTornadoEffective
        self.significantHail = significantHail
        self.bunkersRightMotion = bunkersRightMotion
        self.bunkersLeftMotion = bunkersLeftMotion
        self.stormRelativeWind46km = stormRelativeWind46km
        self.meanWind850300mb = meanWind850300mb
        self.diagnostics = diagnostics
    }
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
            tempDewPtDeltaF != nil || temperatureDewpointSpreadF != nil,
            threeCapeJkg != nil,
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
    case temperature2mK
    case dewpoint2mK
    case tempDewPtDeltaF
    case threeCapeJkg
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
