import Foundation
import Vapor
import ArcusCore

struct TornadoIngredientSnapshot: Content, Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
    let source: StormSetupSourceMetadata
    let raw: TornadoRawParameters
    let canonical: TornadoRawParameters?
    let surfaceHeightMslM: Double?
    let assessment: TornadoIngredientAssessment
    let freshness: IngredientFreshness
    let anvilEvidence: AnvilIngredientEvidence?

    init(
        h3Cell: Int64,
        centroid: StormSetupCentroid,
        source: StormSetupSourceMetadata,
        raw: TornadoRawParameters,
        canonical: TornadoRawParameters? = nil,
        surfaceHeightMslM: Double? = nil,
        assessment: TornadoIngredientAssessment,
        freshness: IngredientFreshness,
        anvilEvidence: AnvilIngredientEvidence? = nil
    ) {
        self.h3Cell = h3Cell
        self.centroid = centroid
        self.source = source
        self.raw = raw
        self.canonical = canonical
        self.surfaceHeightMslM = surfaceHeightMslM
        self.assessment = assessment
        self.freshness = freshness
        self.anvilEvidence = anvilEvidence
    }

    var canonicalIngredients: TornadoRawParameters {
        canonical ?? raw
    }
}

struct StormSetupResolvedH3Cell: Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
}
