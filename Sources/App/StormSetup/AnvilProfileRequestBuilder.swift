import Foundation
import SwiftyH3

struct AnvilProfileRequestBuilder: Sendable {
    let h3Resolver: any StormSetupH3Resolving
    let minimumRetainedLevels: Int

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        minimumRetainedLevels: Int = 5
    ) {
        self.h3Resolver = h3Resolver
        self.minimumRetainedLevels = minimumRetainedLevels
    }

    func build(
        h3Cell: Int64,
        runTime: Date,
        forecastHour: Int,
        groupedProfile: StormSetupPressureProfileGroupingResult
    ) throws -> AnvilProfileRequestBuildResult {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)

        let retainedLevels = groupedProfile.retainedLevels
        guard !retainedLevels.isEmpty else {
            throw AnvilProfileRequestBuilderError.noRetainedLevels
        }
        guard retainedLevels.count >= minimumRetainedLevels else {
            throw AnvilProfileRequestBuilderError.tooFewRetainedLevels(
                actual: retainedLevels.count,
                minimum: minimumRetainedLevels
            )
        }

        let profileArrays = try ProfileArrays(levels: retainedLevels)
        let validTime = runTime.addingTimeInterval(TimeInterval(forecastHour) * 3600)
        let warnings = makeWarnings(for: groupedProfile, profileLevels: retainedLevels)

        return AnvilProfileRequestBuildResult(
            request: AnvilAnalyzeProfileRequest(
                runTime: runTime,
                forecastHour: forecastHour,
                validTime: validTime,
                location: AnvilLocationDTO(
                    lat: resolved.centroid.latitude,
                    lon: resolved.centroid.longitude,
                    h3: h3String(for: resolved.h3Cell)
                ),
                profile: profileArrays.profiles
            ),
            warnings: warnings
        )
    }

    private func makeWarnings(
        for groupedProfile: StormSetupPressureProfileGroupingResult,
        profileLevels: [StormSetupPressureProfileLevel]
    ) -> [AnvilProfileRequestWarning] {
        var warnings: [AnvilProfileRequestWarning] = []

        if !groupedProfile.droppedLevels.isEmpty {
            warnings.append(.droppedLevels(groupedProfile.droppedLevels))
        }

        for index in profileLevels.indices.dropFirst() {
            let previousLevel = profileLevels[index - 1]
            let currentLevel = profileLevels[index]
            if currentLevel.heightMslM <= previousLevel.heightMslM {
                warnings.append(
                    .nonMonotonicHeight(
                        previousPressureMb: previousLevel.pressureMb,
                        previousHeightMslM: previousLevel.heightMslM,
                        pressureMb: currentLevel.pressureMb,
                        heightMslM: currentLevel.heightMslM
                    )
                )
            }
        }

        return warnings
    }

    private func h3String(for h3Cell: Int64) -> String {
        H3Cell(UInt64(bitPattern: h3Cell)).description
    }

    struct ProfileArrays: Sendable, Equatable {
        let levels: [StormSetupPressureProfileLevel]
        let pressureMb: [Double]
        let heightMslM: [Double]
        let temperatureC: [Double]
        let dewpointC: [Double]
        let uWindMs: [Double]
        let vWindMs: [Double]

        init(levels: [StormSetupPressureProfileLevel]) throws {
            guard let violation = Self.firstPressureViolation(
                in: levels.map { Double($0.pressureMb) }
            ) else {
                let sortedLevels = levels.sorted(by: { $0.pressureMb > $1.pressureMb })

                self.levels = sortedLevels
                self.pressureMb = sortedLevels.map { Double($0.pressureMb) }
                self.heightMslM = sortedLevels.map(\.heightMslM)
                self.temperatureC = sortedLevels.map(\.temperatureC)
                self.dewpointC = sortedLevels.map(\.dewpointC)
                self.uWindMs = sortedLevels.map(\.uWindMs)
                self.vWindMs = sortedLevels.map(\.vWindMs)
                return
            }

            throw AnvilProfileRequestBuilderError.pressureNotStrictlyDescending(
                previousPressureMb: violation.previous,
                pressureMb: violation.current
            )
        }

        init(
            pressureMb: [Double],
            heightMslM: [Double],
            temperatureC: [Double],
            dewpointC: [Double],
            uWindMs: [Double],
            vWindMs: [Double]
        ) throws {
            try Self.validateArrayLengths(
                pressureMb: pressureMb,
                heightMslM: heightMslM,
                temperatureC: temperatureC,
                dewpointC: dewpointC,
                uWindMs: uWindMs,
                vWindMs: vWindMs
            )
            guard let violation = Self.firstPressureViolation(in: pressureMb) else {
                self.levels = []
                self.pressureMb = pressureMb
                self.heightMslM = heightMslM
                self.temperatureC = temperatureC
                self.dewpointC = dewpointC
                self.uWindMs = uWindMs
                self.vWindMs = vWindMs
                return
            }

            throw AnvilProfileRequestBuilderError.pressureNotStrictlyDescending(
                previousPressureMb: violation.previous,
                pressureMb: violation.current
            )
        }

        var profiles: [AnvilProfileDTO] {
            zip6(pressureMb, heightMslM, temperatureC, dewpointC, uWindMs, vWindMs).map {
                AnvilProfileDTO(
                    pressureMb: $0.0,
                    heightMslM: $0.1,
                    temperatureC: $0.2,
                    dewpointC: $0.3,
                    uWindMs: $0.4,
                    vWindMs: $0.5
                )
            }
        }

        private static func validateArrayLengths(
            pressureMb: [Double],
            heightMslM: [Double],
            temperatureC: [Double],
            dewpointC: [Double],
            uWindMs: [Double],
            vWindMs: [Double]
        ) throws {
            let lengths = [
                pressureMb.count,
                heightMslM.count,
                temperatureC.count,
                dewpointC.count,
                uWindMs.count,
                vWindMs.count
            ]
            guard Set(lengths).count == 1, let expected = lengths.first else {
                throw AnvilProfileRequestBuilderError.unequalArrayLengths(
                    expected: pressureMb.count,
                    actual: [
                        heightMslM.count,
                        temperatureC.count,
                        dewpointC.count,
                        uWindMs.count,
                        vWindMs.count
                    ]
                    .first(where: { $0 != pressureMb.count }) ?? pressureMb.count
                )
            }
            guard expected > 0 else {
                throw AnvilProfileRequestBuilderError.noRetainedLevels
            }
        }

        private static func firstPressureViolation(in pressureMb: [Double]) -> (previous: Double, current: Double)? {
            guard pressureMb.count > 1 else {
                return nil
            }

            for index in pressureMb.indices.dropFirst() {
                if pressureMb[index - 1] <= pressureMb[index] {
                    return (previous: pressureMb[index - 1], current: pressureMb[index])
                }
            }

            return nil
        }
    }
}

struct AnvilProfileRequestBuildResult: Sendable, Equatable {
    let request: AnvilAnalyzeProfileRequest
    let warnings: [AnvilProfileRequestWarning]
}

enum AnvilProfileRequestWarning: Sendable, Equatable {
    case droppedLevels([StormSetupPressureProfileMissingLevel])
    case nonMonotonicHeight(
        previousPressureMb: Int,
        previousHeightMslM: Double,
        pressureMb: Int,
        heightMslM: Double
    )
}

enum AnvilProfileRequestBuilderError: Error, Sendable, Equatable {
    case noRetainedLevels
    case tooFewRetainedLevels(actual: Int, minimum: Int)
    case unequalArrayLengths(expected: Int, actual: Int)
    case pressureNotStrictlyDescending(previousPressureMb: Double, pressureMb: Double)
}

private func zip6<A, B, C, D, E, F>(
    _ a: [A],
    _ b: [B],
    _ c: [C],
    _ d: [D],
    _ e: [E],
    _ f: [F]
) -> [(A, B, C, D, E, F)] {
    zip(zip(zip(zip(zip(a, b), c), d), e), f).map { combined in
        let ((((ab, c), d), e), f) = combined
        let (a, b) = ab
        return (a, b, c, d, e, f)
    }
}
