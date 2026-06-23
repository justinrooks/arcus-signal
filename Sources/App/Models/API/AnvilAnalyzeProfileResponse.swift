import Foundation

struct AnvilAnalyzeProfileResponse: Codable, Sendable, Equatable {
    let status: String
    let diagnostics: [AnvilAnalyzeProfileResponseDiagnosticDTO]?
    let scp: Double?
    let stp: Double?
    let ship: Double?
}

struct AnvilAnalyzeProfileResponseDiagnosticDTO: Codable, Sendable, Equatable {
    let status: String
    let code: String?
    let message: String
}
