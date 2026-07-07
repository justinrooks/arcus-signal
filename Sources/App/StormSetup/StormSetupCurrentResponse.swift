import Foundation
import Vapor

struct StormSetupCurrentResponse: Content, Sendable {
    let setup: StormSetupCurrentSetupResponse
    let ingredients: TornadoRawParameters
    let profileAnalysis: AnvilAnalyzeProfileResponse?
    let assessment: TornadoIngredientAssessment
}

struct StormSetupCurrentSetupResponse: Content, Sendable {
    let h3Cell: Int64
    let centroid: StormSetupCentroid
    let source: StormSetupSourceMetadata
    let surfaceHeightMslM: Double?
    let freshness: IngredientFreshness
}
