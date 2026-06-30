import Foundation

struct AnvilAnalyzeProfileRequest: Codable, Sendable, Equatable {
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let location: AnvilLocationDTO
    let profile: AnvilProfileDTO
}

struct AnvilLocationDTO: Codable, Sendable, Equatable {
    let lat: Double
    let lon: Double
    let h3: String
}

struct AnvilProfileDTO: Codable, Sendable, Equatable {
    let pressureMb: [Double]
    let heightMslM: [Double]
    let temperatureC: [Double]
    let dewpointC: [Double]
    let uWindMs: [Double]
    let vWindMs: [Double]
}
