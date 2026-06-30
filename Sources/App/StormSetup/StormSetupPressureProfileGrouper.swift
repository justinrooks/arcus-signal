import Foundation

struct StormSetupPressureProfileGrouper: Sendable {
    func group(
        samples: [HrrrFieldSample],
        surfaceHeightMslM: Double? = nil,
        surfaceHeightToleranceM: Double = 1.0
    ) -> StormSetupPressureProfileGroupingResult {
        var draftsByLevel: [StormSetupPressureLevel: Draft] = [:]
        var ignoredSamples: [StormSetupPressureProfileIgnoredSample] = []

        for sample in samples {
            let point = sample.point

            guard let descriptor = point.inventoryDescriptor else {
                ignoredSamples.append(
                    StormSetupPressureProfileIgnoredSample(
                        inventory: point.inventory,
                        reason: .missingDescriptor
                    )
                )
                continue
            }

            guard let variable = StormSetupPressureProfileVariable(normalizedToken: descriptor.variable) else {
                ignoredSamples.append(
                    StormSetupPressureProfileIgnoredSample(
                        inventory: point.inventory,
                        reason: .unsupportedVariable(descriptor.variable)
                    )
                )
                continue
            }

            guard let level = StormSetupPressureLevel.parse(from: descriptor.level) else {
                ignoredSamples.append(
                    StormSetupPressureProfileIgnoredSample(
                        inventory: point.inventory,
                        reason: .unsupportedPressureLevel(descriptor.level)
                    )
                )
                continue
            }

            guard let value = point.value else {
                ignoredSamples.append(
                    StormSetupPressureProfileIgnoredSample(
                        inventory: point.inventory,
                        reason: .missingValue
                    )
                )
                continue
            }

            var draft = draftsByLevel[level] ?? Draft(pressureMb: level.pressureMb)
            draft.record(variable: variable, value: convert(value, for: variable))
            draftsByLevel[level] = draft
        }

        var retainedLevels: [StormSetupPressureProfileLevel] = []
        var missingLevels: [StormSetupPressureProfileMissingLevel] = []
        var droppedLevels: [StormSetupPressureProfileDroppedLevel] = []

        for level in StormSetupPressureLevel.preferredDescending {
            guard let draft = draftsByLevel[level] else {
                missingLevels.append(
                    StormSetupPressureProfileMissingLevel(
                        pressureMb: level.pressureMb,
                        missingVariables: StormSetupPressureProfileVariable.allCases
                    )
                )
                droppedLevels.append(
                    StormSetupPressureProfileDroppedLevel(
                        pressureMb: level.pressureMb,
                        reason: .incomplete(
                            missingVariables: StormSetupPressureProfileVariable.allCases
                        )
                    )
                )
                continue
            }

            let missingVariables = draft.missingVariables
            if missingVariables.isEmpty {
                let levelValue = draft.makeLevel()
                if let surfaceHeightMslM,
                   levelValue.heightMslM <= surfaceHeightMslM + surfaceHeightToleranceM {
                    droppedLevels.append(
                        StormSetupPressureProfileDroppedLevel(
                            pressureMb: levelValue.pressureMb,
                            reason: .belowGround(
                                surfaceHeightMslM: surfaceHeightMslM,
                                levelHeightMslM: levelValue.heightMslM,
                                toleranceM: surfaceHeightToleranceM
                            )
                        )
                    )
                } else {
                    retainedLevels.append(levelValue)
                }
            } else {
                missingLevels.append(
                    StormSetupPressureProfileMissingLevel(
                        pressureMb: level.pressureMb,
                        missingVariables: missingVariables
                    )
                )
                droppedLevels.append(
                    StormSetupPressureProfileDroppedLevel(
                        pressureMb: level.pressureMb,
                        reason: .incomplete(missingVariables: missingVariables)
                    )
                )
            }
        }

        return StormSetupPressureProfileGroupingResult(
            requestedLevels: StormSetupPressureLevel.preferredDescending,
            retainedLevels: retainedLevels,
            missingLevels: missingLevels,
            droppedLevels: droppedLevels,
            ignoredSamples: ignoredSamples
        )
    }

    private func convert(_ value: Double, for variable: StormSetupPressureProfileVariable) -> Double {
        switch variable {
        case .hgt, .ugrd, .vgrd:
            return value
        case .tmp, .dpt:
            return value - Self.kelvinToCelsiusOffset
        }
    }

    private static let kelvinToCelsiusOffset = 273.15
}

private struct Draft: Sendable {
    let pressureMb: Int
    var heightMslM: Double?
    var temperatureC: Double?
    var dewpointC: Double?
    var uWindMs: Double?
    var vWindMs: Double?

    mutating func record(variable: StormSetupPressureProfileVariable, value: Double) {
        switch variable {
        case .hgt:
            if heightMslM == nil {
                heightMslM = value
            }
        case .tmp:
            if temperatureC == nil {
                temperatureC = value
            }
        case .dpt:
            if dewpointC == nil {
                dewpointC = value
            }
        case .ugrd:
            if uWindMs == nil {
                uWindMs = value
            }
        case .vgrd:
            if vWindMs == nil {
                vWindMs = value
            }
        }
    }

    var missingVariables: [StormSetupPressureProfileVariable] {
        var missing: [StormSetupPressureProfileVariable] = []

        if heightMslM == nil {
            missing.append(.hgt)
        }
        if temperatureC == nil {
            missing.append(.tmp)
        }
        if dewpointC == nil {
            missing.append(.dpt)
        }
        if uWindMs == nil {
            missing.append(.ugrd)
        }
        if vWindMs == nil {
            missing.append(.vgrd)
        }

        return missing
    }

    func makeLevel() -> StormSetupPressureProfileLevel {
        precondition(missingVariables.isEmpty, "Attempted to materialize an incomplete pressure profile level.")
        return StormSetupPressureProfileLevel(
            pressureMb: pressureMb,
            heightMslM: heightMslM!,
            temperatureC: temperatureC!,
            dewpointC: dewpointC!,
            uWindMs: uWindMs!,
            vWindMs: vWindMs!
        )
    }
}

private extension StormSetupPressureProfileVariable {
    init?(normalizedToken token: String) {
        let normalized = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.init(rawValue: normalized)
    }
}
