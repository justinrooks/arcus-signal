@testable import App
import Foundation
import Testing
import Vapor
import SwiftyH3

@Suite("Anvil profile request builder", .serialized)
struct AnvilProfileRequestBuilderTests {
    @Test("happy path assembles the frozen request payload")
    func happyPathBuildsFrozenRequestPayload() throws {
        let runTime = makeUTCDate(year: 2026, month: 6, day: 19, hour: 22)
        let forecastHour = 3
        let h3Cell: Int64 = 617_700_169_958_293_503
        let grouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
            ]
        )

        let builder = AnvilProfileRequestBuilder()
        let result = try builder.build(
            h3Cell: h3Cell,
            runTime: runTime,
            forecastHour: forecastHour,
            surfaceLevel: makeSurfaceLevel(),
            groupedProfile: grouping
        )
        let expectedCentroid = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell)

        #expect(result.request.runTime == runTime)
        #expect(result.request.forecastHour == forecastHour)
        #expect(result.request.validTime == makeUTCDate(year: 2026, month: 6, day: 20, hour: 1))
        #expect(result.request.location.lat.isApproximatelyEqual(to: expectedCentroid.centroid.latitude))
        #expect(result.request.location.lon.isApproximatelyEqual(to: expectedCentroid.centroid.longitude))
        #expect(result.request.location.h3 == h3String(for: h3Cell))
        #expect(result.request.profile.pressureMb == [1012.4, 1000, 925, 850, 700, 500])
        #expect(result.request.profile.heightMslM == [320, 1200, 1500, 1800, 2450, 5600])
        #expect(result.request.profile.temperatureC == [29.6, 28.4, 22.8, 17.5, 10.0, -4.2])
        #expect(result.request.profile.dewpointC == [16.4, 12.3, 10.1, 11.2, 1.0, -12.0])
        #expect(result.request.profile.uWindMs == [-1.4, -2.1, -5.4, -6.25, -12.5, -18.75])
        #expect(result.request.profile.vWindMs == [3.8, 4.6, 7.9, 8.75, 14.2, 22.0])
        #expect(result.warnings.isEmpty)
    }

    @Test("validTime is runTime plus forecastHour hours")
    func validTimeUsesRunTimePlusForecastHour() throws {
        let runTime = makeUTCDate(year: 2026, month: 6, day: 19, hour: 22, minute: 15)
        let forecastHour = 9

        let result = try makeBuilder().build(
            h3Cell: 617_700_169_958_293_503,
            runTime: runTime,
            forecastHour: forecastHour,
            surfaceLevel: makeSurfaceLevel(),
            groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
        )

        #expect(result.request.validTime == makeUTCDate(year: 2026, month: 6, day: 20, hour: 7, minute: 15))
    }

    @Test("builder delegates H3 resolution to the existing resolver")
    func builderDelegatesH3Resolution() throws {
        let resolver = RecordingH3Resolver(
                resolved: StormSetupResolvedH3Cell(
                h3Cell: 617_700_169_958_293_503,
                centroid: StormSetupCentroid(latitude: 11.25, longitude: -122.5)
            )
        )
        let builder = AnvilProfileRequestBuilder(h3Resolver: resolver)

        let result = try builder.build(
            h3Cell: 123,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
            forecastHour: 1,
            surfaceLevel: makeSurfaceLevel(),
            groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
        )

        #expect(resolver.resolvedH3Cells == [123])
        #expect(result.request.location.lat == 11.25)
        #expect(result.request.location.lon == -122.5)
        #expect(result.request.location.h3 == h3String(for: resolver.resolved.h3Cell))
    }

    @Test("non-descending pressure is rejected")
    func nonDescendingPressureIsRejected() {
        let builder = makeBuilder()
        let grouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
                makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
            ]
        )

        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try builder.build(
                h3Cell: 617_700_169_958_293_503,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: makeSurfaceLevel(),
                groupedProfile: grouping
            )
        }
    }

    @Test("equal array lengths are enforced by the shared profile-array seam")
    func equalArrayLengthsAreEnforced() {
        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try AnvilProfileRequestBuilder.ProfileArrays(
                pressureMb: [1000, 925],
                heightMslM: [1200],
                temperatureC: [28.4, 22.8],
                dewpointC: [12.3, 10.1],
                uWindMs: [-2.1, -5.4],
                vWindMs: [4.6, 7.9]
            )
        }
    }

    @Test("too few retained levels are rejected")
    func tooFewRetainedLevelsAreRejected() {
        let builder = makeBuilder()

        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try builder.build(
                h3Cell: 617_700_169_958_293_503,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: makeSurfaceLevel(),
                groupedProfile: makeGroupingResult(levels: Array(makeFiveLevelProfile().prefix(4)))
            )
        }
    }

    @Test("surface row is prepended without interpolation")
    func surfaceRowIsPrependedWithoutInterpolation() throws {
        let builder = makeBuilder()
        let surfaceLevel = makeSurfaceLevel(
            pressureMb: 1012,
            heightMslM: 320,
            temperatureC: 29.6,
            dewpointC: 16.4,
            uWindMs: -1.4,
            vWindMs: 3.8
        )

        let result = try builder.build(
            h3Cell: 617_700_169_958_293_503,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
            forecastHour: 3,
            surfaceLevel: surfaceLevel,
            groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
        )

        #expect(result.request.profile.pressureMb == [1012, 1000, 925, 850, 700, 500])
        #expect(result.request.profile.heightMslM == [320, 1200, 1500, 1800, 2450, 5600])
        #expect(result.request.profile.temperatureC == [29.6, 28.4, 22.8, 17.5, 10.0, -4.2])
        #expect(result.request.profile.dewpointC == [16.4, 12.3, 10.1, 11.2, 1.0, -12.0])
        #expect(result.request.profile.uWindMs == [-1.4, -2.1, -5.4, -6.25, -12.5, -18.75])
        #expect(result.request.profile.vWindMs == [3.8, 4.6, 7.9, 8.75, 14.2, 22.0])
    }

    @Test("surface row still requires five retained pressure levels")
    func surfaceRowStillRequiresFiveRetainedPressureLevels() {
        let builder = makeBuilder()
        let surfaceLevel = makeSurfaceLevel(
            pressureMb: 1012,
            heightMslM: 320,
            temperatureC: 29.6,
            dewpointC: 16.4,
            uWindMs: -1.4,
            vWindMs: 3.8
        )

        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try builder.build(
                h3Cell: 617_700_169_958_293_503,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: surfaceLevel,
                groupedProfile: makeGroupingResult(levels: Array(makeFiveLevelProfile().prefix(4)))
            )
        }
    }

    @Test("invalid surface ordering is rejected instead of being sorted away")
    func invalidSurfaceOrderingIsRejectedInsteadOfBeingSortedAway() {
        let builder = makeBuilder()
        let surfaceLevel = makeSurfaceLevel(
            pressureMb: 990,
            heightMslM: 320,
            temperatureC: 29.6,
            dewpointC: 16.4,
            uWindMs: -1.4,
            vWindMs: 3.8
        )

        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try builder.build(
                h3Cell: 617_700_169_958_293_503,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: surfaceLevel,
                groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
            )
        }
    }

    @Test("surface height must be below the first retained pressure level")
    func invalidSurfaceHeightIsRejected() {
        let surfaceLevel = makeSurfaceLevel(
            pressureMb: 1_012,
            heightMslM: 1_200
        )

        #expect(throws: AnvilProfileRequestBuilderError.self) {
            _ = try makeBuilder().build(
                h3Cell: 617_700_169_958_293_503,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: surfaceLevel,
                groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
            )
        }
    }

    @Test("invalid H3 cells fail through the existing resolver")
    func invalidH3CellsFailThroughExistingResolver() {
        let builder = makeBuilder()

        #expect(throws: Abort.self) {
            _ = try builder.build(
                h3Cell: 0,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
                forecastHour: 3,
                surfaceLevel: makeSurfaceLevel(),
                groupedProfile: makeGroupingResult(levels: makeFiveLevelProfile())
            )
        }
    }

    @Test("height monotonicity produces a warning without blocking request assembly")
    func heightMonotonicityProducesWarning() throws {
        let builder = makeBuilder()
        let grouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 850, heightMslM: 1450, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 700, heightMslM: 2600, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
            ]
        )

        let result = try builder.build(
            h3Cell: 617_700_169_958_293_503,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
            forecastHour: 3,
            surfaceLevel: makeSurfaceLevel(),
            groupedProfile: grouping
        )

        #expect(result.warnings.contains(where: { warning in
            switch warning {
            case .nonMonotonicHeight(
                previousPressureMb: 925,
                previousHeightMslM: 1500,
                pressureMb: 850,
                heightMslM: 1450
            ):
                return true
            default:
                return false
            }
        }))
        #expect(result.request.profile.pressureMb.count == 6)
    }

    @Test("dropped levels are surfaced as quality warnings")
    func droppedLevelsAreSurfacedAsWarnings() throws {
        let builder = makeBuilder()
        let grouping = makeGroupingResult(
            levels: makeFiveLevelProfile(),
            droppedLevels: [
                StormSetupPressureProfileDroppedLevel(
                    pressureMb: 775,
                    reason: .incomplete(missingVariables: [.hgt, .tmp, .dpt, .ugrd, .vgrd])
                )
            ]
        )

        let result = try builder.build(
            h3Cell: 617_700_169_958_293_503,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
            forecastHour: 3,
            surfaceLevel: makeSurfaceLevel(),
            groupedProfile: grouping
        )

        #expect(result.warnings.contains(where: { warning in
            if case .droppedLevels(let levels) = warning {
                return levels == grouping.droppedLevels
            }
            return false
        }))
    }

    @Test("below-ground levels are dropped before request assembly and surfaced in warnings")
    func belowGroundLevelsAreDroppedBeforeRequestAssembly() throws {
        let builder = makeBuilder()
        let grouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 600, heightMslM: 4100, temperatureC: 3.2, dewpointC: -2.6, uWindMs: -15.25, vWindMs: 18.4),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
            ],
            droppedLevels: [
                StormSetupPressureProfileDroppedLevel(
                    pressureMb: 1000,
                    reason: .belowGround(
                        surfaceHeightMslM: 1300,
                        levelHeightMslM: 1200,
                        toleranceM: 1
                    )
                )
            ]
        )

        let result = try builder.build(
            h3Cell: 617_700_169_958_293_503,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 22),
            forecastHour: 3,
            surfaceLevel: makeSurfaceLevel(
                pressureMb: 940,
                heightMslM: 1_300
            ),
            groupedProfile: grouping
        )

        #expect(result.request.profile.pressureMb == [940, 925, 850, 700, 600, 500])
        #expect(result.warnings.contains(where: { warning in
            if case .droppedLevels(let levels) = warning {
                return levels == grouping.droppedLevels
            }
            return false
        }))
    }

    private func makeBuilder() -> AnvilProfileRequestBuilder {
        AnvilProfileRequestBuilder()
    }

    private func makeSurfaceLevel(
        pressureMb: Double = 1_012.4,
        heightMslM: Double = 320,
        temperatureC: Double = 29.6,
        dewpointC: Double = 16.4,
        uWindMs: Double = -1.4,
        vWindMs: Double = 3.8
    ) -> StormSetupSurfaceProfileLevel {
        StormSetupSurfaceProfileLevel(
            pressureMb: pressureMb,
            heightMslM: heightMslM,
            temperatureC: temperatureC,
            dewpointC: dewpointC,
            uWindMs: uWindMs,
            vWindMs: vWindMs
        )
    }

    private func makeFiveLevelProfile() -> [StormSetupPressureProfileLevel] {
        [
            makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
            makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
            makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
            makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
            makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
        ]
    }

    private func makeGroupingResult(
        levels: [StormSetupPressureProfileLevel],
        missingLevels: [StormSetupPressureProfileMissingLevel] = [],
        droppedLevels: [StormSetupPressureProfileDroppedLevel] = []
    ) -> StormSetupPressureProfileGroupingResult {
        let resolvedMissingLevels = missingLevels.isEmpty
            ? droppedLevels.compactMap { droppedLevel -> StormSetupPressureProfileMissingLevel? in
                guard case .incomplete(let missingVariables) = droppedLevel.reason else {
                    return nil
                }
                return StormSetupPressureProfileMissingLevel(
                    pressureMb: droppedLevel.pressureMb,
                    missingVariables: missingVariables
                )
            }
            : missingLevels

        return StormSetupPressureProfileGroupingResult(
            requestedLevels: StormSetupPressureLevel.preferredDescending,
            retainedLevels: levels,
            missingLevels: resolvedMissingLevels,
            droppedLevels: droppedLevels,
            ignoredSamples: []
        )
    }

    private func makeLevel(
        pressureMb: Int,
        heightMslM: Double,
        temperatureC: Double,
        dewpointC: Double,
        uWindMs: Double,
        vWindMs: Double
    ) -> StormSetupPressureProfileLevel {
        StormSetupPressureProfileLevel(
            pressureMb: pressureMb,
            heightMslM: heightMslM,
            temperatureC: temperatureC,
            dewpointC: dewpointC,
            uWindMs: uWindMs,
            vWindMs: vWindMs
        )
    }

    private func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        let components = DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )

        guard let date = StormSetupUTC.calendar.date(from: components) else {
            preconditionFailure("Unable to create UTC date for test.")
        }

        return date
    }

    private func h3String(for h3Cell: Int64) -> String {
        H3Cell(UInt64(bitPattern: h3Cell)).description
    }
}

private final class RecordingH3Resolver: StormSetupH3Resolving, @unchecked Sendable {
    let resolved: StormSetupResolvedH3Cell
    private(set) var resolvedH3Cells: [Int64] = []

    init(resolved: StormSetupResolvedH3Cell) {
        self.resolved = resolved
    }

    func resolve(h3Cell: Int64) throws -> StormSetupResolvedH3Cell {
        resolvedH3Cells.append(h3Cell)
        return resolved
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.0000001) -> Bool {
        abs(self - other) <= tolerance
    }
}
