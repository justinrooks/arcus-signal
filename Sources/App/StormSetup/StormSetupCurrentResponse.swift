import Foundation
import Vapor

struct StormSetupCurrentResponse: Content, Sendable {
    let setup: StormSetupCurrentSetupResponse
    let ingredients: StormSetupTornadoIngredientsResponse
    let profileAnalysis: AnvilAnalyzeProfileResponse?
    let tornadoViability: TornadoViabilityReport
}

struct StormSetupCurrentSetupResponse: Content, Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
    let source: StormSetupSourceMetadata
    let surfaceHeightMslM: Double?
    let freshness: IngredientFreshness
}

struct StormSetupTornadoIngredientsResponse: Content, Sendable, Equatable {
    let canonical: TornadoRawParameters
    let diagnostics: TornadoRawParameters
}

struct TornadoViabilityReport: Content, Sendable, Equatable {
    let overall: IngredientSupport
    let confidence: SnapshotConfidence
    let summary: String
    let details: TornadoViabilityDetails
    let limitingFactors: [TornadoLimitingFactor]
}

struct TornadoViabilityDetails: Content, Sendable, Equatable {
    let instability: IngredientSupport
    let moisture: IngredientSupport
    let cloudBase: IngredientSupport
    let capInhibition: IngredientSupport
    let deepShear: IngredientSupport
    let lowLevelRotation: IngredientSupport
    let stormMode: IngredientSupport
    let compositeSignal: IngredientSupport
}

extension TornadoViabilityReport {
    init(diagnosis: TornadoViabilityDiagnosis) {
        self.init(
            overall: diagnosis.overall,
            confidence: diagnosis.confidence,
            summary: diagnosis.summary,
            details: TornadoViabilityDetails(
                instability: diagnosis.instability,
                moisture: diagnosis.moisture,
                cloudBase: diagnosis.cloudBase,
                capInhibition: diagnosis.capInhibition,
                deepShear: diagnosis.deepShear,
                lowLevelRotation: diagnosis.lowLevelRotation,
                stormMode: diagnosis.stormMode,
                compositeSignal: diagnosis.compositeSignal
            ),
            limitingFactors: diagnosis.limitingFactors
        )
    }

    init(assessment: TornadoIngredientAssessment) {
        self.init(
            overall: assessment.overall,
            confidence: assessment.confidence,
            summary: assessment.summary,
            details: TornadoViabilityDetails(
                instability: assessment.instability,
                moisture: assessment.moisture,
                cloudBase: assessment.cloudBase,
                capInhibition: assessment.capInhibition,
                deepShear: assessment.deepShear,
                lowLevelRotation: assessment.lowLevelRotation,
                stormMode: assessment.stormMode,
                compositeSignal: assessment.compositeSignal
            ),
            limitingFactors: assessment.limitingFactors
        )
    }
}
