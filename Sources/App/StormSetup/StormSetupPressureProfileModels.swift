import Foundation

struct StormSetupPressureProfileLevel: Sendable, Equatable {
    let pressureMb: Int
    let heightMslM: Double
    let temperatureC: Double
    let dewpointC: Double
    let uWindMs: Double
    let vWindMs: Double
}

struct StormSetupPressureProfileMissingLevel: Sendable, Equatable {
    let pressureMb: Int
    let missingVariables: [StormSetupPressureProfileVariable]
}

struct StormSetupPressureProfileDroppedLevel: Sendable, Equatable {
    let pressureMb: Int
    let reason: StormSetupPressureProfileDroppedLevelReason
}

enum StormSetupPressureProfileDroppedLevelReason: Sendable, Equatable {
    case incomplete(missingVariables: [StormSetupPressureProfileVariable])
    case belowGround(
        surfaceHeightMslM: Double,
        levelHeightMslM: Double,
        toleranceM: Double
    )
}

struct StormSetupPressureProfileIgnoredSample: Sendable, Equatable {
    let inventory: String
    let reason: StormSetupPressureProfileIgnoredSampleReason
}

enum StormSetupPressureProfileIgnoredSampleReason: Sendable, Equatable {
    case missingDescriptor
    case unsupportedVariable(String)
    case unsupportedPressureLevel(String)
    case missingValue
}

struct StormSetupPressureProfileGroupingResult: Sendable, Equatable {
    let requestedLevels: [StormSetupPressureLevel]
    let retainedLevels: [StormSetupPressureProfileLevel]
    let missingLevels: [StormSetupPressureProfileMissingLevel]
    let droppedLevels: [StormSetupPressureProfileDroppedLevel]
    let ignoredSamples: [StormSetupPressureProfileIgnoredSample]
}
