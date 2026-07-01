import Foundation

struct StormSetupSurfaceProfileLevel: Sendable, Equatable {
    let pressureMb: Double
    let heightMslM: Double
    let temperatureC: Double
    let dewpointC: Double
    let uWindMs: Double
    let vWindMs: Double
}

enum AnvilSurfaceProfileField: String, CaseIterable, Sendable, Equatable {
    case pressure = "PRES"
    case height = "HGT"
    case temperature = "TMP"
    case dewpoint = "DPT"
    case uWind = "UGRD"
    case vWind = "VGRD"
}

struct AnvilSurfaceProfileNormalizationError: Error, Sendable, Equatable, CustomStringConvertible {
    let invalidFields: [AnvilSurfaceProfileField]

    var description: String {
        "Matching surface profile was incomplete or invalid for fields: \(invalidFields.map(\.rawValue).joined(separator: ", "))."
    }
}
