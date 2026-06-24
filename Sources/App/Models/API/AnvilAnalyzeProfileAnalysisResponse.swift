import Foundation
import Vapor

struct AnvilAnalyzeProfileAnalysisResponse: Content, Sendable, Equatable {
    let request: AnvilAnalyzeProfileRequest
    let debug: AnvilAnalyzeProfilePreviewDebugDTO
    let response: AnvilAnalyzeProfileResponse
}
