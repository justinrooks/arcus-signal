import Foundation
import Vapor
import ArcusCore

struct AnvilAnalyzeProfileAnalysisResponse: Content, Sendable, Equatable {
    let request: AnvilAnalyzeProfileRequest
    let debug: AnvilAnalyzeProfilePreviewDebugDTO
    let response: AnvilAnalyzeProfileResponse
}
