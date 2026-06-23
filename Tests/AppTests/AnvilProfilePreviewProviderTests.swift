@testable import App
import Foundation
import Testing
import SwiftyH3
import Vapor

@Suite("Anvil profile preview provider", .serialized)
struct AnvilProfilePreviewProviderTests {
    @Test("provider falls back to the next pressure candidate when the newest source is unavailable")
    func providerFallsBackAcrossCandidates() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell)
        let firstCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let secondCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
            forecastHour: 1
        )
        let resolver = PreviewStaticHrrrRunResolver(
            resolution: HrrrRunResolution(
                targetValidTime: now.truncatedToHour,
                candidates: [firstCandidate, secondCandidate]
            )
        )
        let dateProvider = PreviewFixedStormSetupDateProvider(nowDate: now)
        let pressureSourceResolver = PreviewStubPressureSourceResolver { callIndex, resolution in
            guard let candidate = resolution.candidates.first else {
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "missing pressure candidate"
                )
            }

            switch callIndex {
            case 0:
                throw AnvilProfilePreviewError.upstreamUnavailable(
                    reason: "AWS pressure object unavailable for \(candidate.fileName)."
                )
            case 1:
                return previewMakePressureSourceResolution(
                    candidate: makeShiftedPressureCandidate(from: candidate),
                    idxAvailable: true
                )
            default:
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "unexpected extra source-resolution call"
                )
            }
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { callIndex, sourceResolution, centroid in
            #expect(callIndex == 0)
            #expect(sourceResolution.idxProbe.available == true)
            #expect(centroid == expected.centroid)
            return previewMakePressureProfileLoadResult(
                sourceResolution: sourceResolution,
                fetchedAt: now,
                subsetCacheHit: true,
                samples: previewMakePressureSamples(
                    level: 1000,
                    hgt: 1200,
                    tmp: 301.55,
                    dpt: 285.45,
                    ugrd: -2.1,
                    vgrd: 4.6
                ) + previewMakePressureSamples(
                    level: 925,
                    hgt: 1500,
                    tmp: 295.95,
                    dpt: 283.25,
                    ugrd: -5.4,
                    vgrd: 7.9
                ) + previewMakePressureSamples(
                    level: 850,
                    hgt: 1800,
                    tmp: 290.65,
                    dpt: 284.35,
                    ugrd: -6.25,
                    vgrd: 8.75
                ) + previewMakePressureSamples(
                    level: 700,
                    hgt: 2450,
                    tmp: 283.15,
                    dpt: 274.15,
                    ugrd: -12.5,
                    vgrd: 14.2
                ) + previewMakePressureSamples(
                    level: 500,
                    hgt: 5600,
                    tmp: 268.95,
                    dpt: 261.15,
                    ugrd: -18.75,
                    vgrd: 22.0
                )
            )
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: dateProvider,
            hrrrRunResolver: resolver,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        let preview = try await provider.previewProfile(for: h3Cell)
        let expectedGrouping = makeGroupingResult(
            levels: [
                makeLevel(pressureMb: 1000, heightMslM: 1200, temperatureC: 28.4, dewpointC: 12.3, uWindMs: -2.1, vWindMs: 4.6),
                makeLevel(pressureMb: 925, heightMslM: 1500, temperatureC: 22.8, dewpointC: 10.1, uWindMs: -5.4, vWindMs: 7.9),
                makeLevel(pressureMb: 850, heightMslM: 1800, temperatureC: 17.5, dewpointC: 11.2, uWindMs: -6.25, vWindMs: 8.75),
                makeLevel(pressureMb: 700, heightMslM: 2450, temperatureC: 10.0, dewpointC: 1.0, uWindMs: -12.5, vWindMs: 14.2),
                makeLevel(pressureMb: 500, heightMslM: 5600, temperatureC: -4.2, dewpointC: -12.0, uWindMs: -18.75, vWindMs: 22.0)
            ],
            missingLevels: makeMissingLevels(excluding: [1000, 925, 850, 700, 500])
        )
        let expectedRequest = try AnvilProfileRequestBuilder().build(
            h3Cell: h3Cell,
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
            forecastHour: 1,
            groupedProfile: expectedGrouping
        ).request

        #expect(preview.request == expectedRequest)
        #expect(preview.debug.sourceKind == .directObject)
        #expect(preview.debug.product == .wrfprsf)
        #expect(preview.debug.runTime == previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21))
        #expect(preview.debug.forecastHour == 1)
        #expect(preview.debug.validTime == previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
        #expect(preview.debug.h3 == expected.request.location.h3)
        #expect(preview.debug.centroid == expected.centroid)
        #expect(preview.debug.selectedMessageCount == 5)
        #expect(preview.debug.selectedPressureLevels == [1000])
        #expect(preview.debug.rangeCount == 5)
        #expect(preview.debug.totalSelectedRangeBytes == 1024)
        #expect(preview.debug.subsetCacheHit == true)
        #expect(preview.debug.primaryDownloadURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260603/conus/hrrr.t21z.wrfprsf01.grib2")
        #expect(preview.debug.idxURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260603/conus/hrrr.t21z.wrfprsf01.grib2.idx")
        #expect(preview.debug.idxAvailable == true)
        #expect(preview.debug.gribAvailable == nil)
        #expect(preview.debug.pressureLevelsRetained == [1000, 925, 850, 700, 500])
        #expect(preview.debug.warnings.contains(where: { $0.contains("Dropped incomplete pressure levels") }))
    }

    @Test("provider surfaces unusable profile failures when too few levels are retained")
    func providerSurfacesUnusableProfile() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let firstCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let resolver = PreviewStaticHrrrRunResolver(
            resolution: HrrrRunResolution(
                targetValidTime: now.truncatedToHour,
                candidates: [firstCandidate]
            )
        )
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, resolution in
            guard let candidate = resolution.candidates.first else {
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "missing pressure candidate"
                )
            }
            return previewMakePressureSourceResolution(
                candidate: makeShiftedPressureCandidate(from: candidate),
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _ in
            let result = previewMakePressureProfileLoadResult(
                sourceResolution: sourceResolution,
                fetchedAt: now,
                samples: previewMakePressureSamples(
                    level: 1000,
                    hgt: 1200,
                    tmp: 301.55,
                    dpt: 285.45,
                    ugrd: -2.1,
                    vgrd: 4.6
                ) + previewMakePressureSamples(
                    level: 925,
                    hgt: 1500,
                    tmp: 295.95,
                    dpt: 283.25,
                    ugrd: -5.4,
                    vgrd: 7.9
                ) + previewMakePressureSamples(
                    level: 850,
                    hgt: 1800,
                    tmp: 290.65,
                    dpt: 284.35,
                    ugrd: -6.25,
                    vgrd: 8.75
                ) + previewMakePressureSamples(
                    level: 700,
                    hgt: 2450,
                    tmp: 283.15,
                    dpt: 274.15,
                    ugrd: -12.5,
                    vgrd: 14.2
                )
            )
            return HrrrPressureProfileLoadResult(
                sourceResolution: result.sourceResolution,
                inventory: result.inventory,
                selection: result.selection,
                byteRangePlan: result.byteRangePlan,
                subsetCacheResult: result.subsetCacheResult,
                samples: result.samples,
                groupedProfile: result.groupedProfile
            )
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: resolver,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the preview provider to fail with unusable profile data.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile(let reason) = error {
                #expect(reason.contains("Only 4 retained levels"))
                #expect(reason.contains("Missing or incomplete levels"))
                return
            }
            Issue.record("Expected unusable profile error but got \(error).")
        }
    }

    @Test("provider surfaces invalid H3 cells before any pressure lookups")
    func providerSurfacesInvalidH3() async throws {
        let provider = DefaultAnvilProfilePreviewProvider(
            pressureSourceResolver: PreviewStubPressureSourceResolver { _, _ in
                Issue.record("Pressure source resolver should not have been called for an invalid H3 cell.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected call")
            },
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _ in
                Issue.record("Pressure profile loader should not have been called for an invalid H3 cell.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected call")
            }
        )

        do {
            _ = try await provider.previewProfile(for: 0)
            Issue.record("Expected invalid H3 resolution to fail.")
        } catch let error as Abort {
            #expect(error.status == .badRequest)
        }
    }

    @Test("provider surfaces upstream unavailable pressure source failures")
    func providerSurfacesUpstreamUnavailable() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let candidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [candidate])
            ),
            pressureSourceResolver: PreviewStubPressureSourceResolver { _, _ in
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "AWS pressure object unavailable")
            },
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _ in
                Issue.record("Pressure profile loader should not have been called after source resolution failed.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected call")
            }
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected an upstream unavailable failure.")
        } catch let error as AnvilProfilePreviewError {
            if case .upstreamUnavailable = error {
                return
            }
            Issue.record("Expected upstream unavailable error but got \(error).")
        }
    }

    @Test("provider surfaces internal execution failures from wgrib2 sampling")
    func providerSurfacesInternalExecutionFailure() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let candidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [candidate])
            ),
            pressureSourceResolver: PreviewStubPressureSourceResolver { _, resolution in
                guard let candidate = resolution.candidates.first else {
                    throw AnvilProfilePreviewError.internalExecutionFailure(
                        reason: "missing pressure candidate"
                    )
                }
                return previewMakePressureSourceResolution(
                    candidate: makeShiftedPressureCandidate(from: candidate),
                    idxAvailable: true
                )
            },
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _ in
                throw AnvilProfilePreviewError.internalExecutionFailure(reason: "wgrib2 exited with code 1")
            }
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected an internal execution failure.")
        } catch let error as AnvilProfilePreviewError {
            if case .internalExecutionFailure = error {
                return
            }
            Issue.record("Expected internal execution failure but got \(error).")
        }
    }
}

private func previewMakePressureSourceResolution(
    candidate: HrrrRunCandidate,
    idxAvailable: Bool
) -> HrrrPressureDirectObjectResolution {
    let builder = HrrrPressureDirectObjectURLBuilder()
    let source = builder.makeSourceMetadata(for: candidate)
    let idxURL = source.idxURL ?? builder.makeIdxURL(for: candidate)

    return HrrrPressureDirectObjectResolution(
        candidate: candidate,
        source: source,
        idxProbe: HrrrRemoteObjectProbeResult(
            url: idxURL,
            available: idxAvailable,
            status: idxAvailable ? 200 : 404
        ),
        gribProbe: nil
    )
}

private func makeShiftedPressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
    HrrrRunCandidate(
        model: candidate.model,
        product: .wrfprsf,
        domain: candidate.domain,
        runTime: StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: candidate.runTime) ?? candidate.runTime,
        forecastHour: candidate.forecastHour + 1,
        fieldSetVersion: .tornadoPressureV1
    )
}

private func makeGroupingResult(
    levels: [StormSetupPressureProfileLevel],
    missingLevels: [StormSetupPressureProfileMissingLevel] = []
) -> StormSetupPressureProfileGroupingResult {
    StormSetupPressureProfileGroupingResult(
        requestedLevels: StormSetupPressureLevel.preferredDescending,
        retainedLevels: levels,
        missingLevels: missingLevels,
        ignoredSamples: []
    )
}

private func makeMissingLevels(excluding retainedPressureLevels: [Int]) -> [StormSetupPressureProfileMissingLevel] {
    let retained = Set(retainedPressureLevels)
    return StormSetupPressureLevel.preferredDescending
        .filter { !retained.contains($0.pressureMb) }
        .map {
            StormSetupPressureProfileMissingLevel(
                pressureMb: $0.pressureMb,
                missingVariables: [.hgt, .tmp, .dpt, .ugrd, .vgrd]
            )
        }
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

private extension Date {
    var truncatedToHour: Date {
        StormSetupUTC.calendar.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: StormSetupUTC.calendar.component(.year, from: self),
                month: StormSetupUTC.calendar.component(.month, from: self),
                day: StormSetupUTC.calendar.component(.day, from: self),
                hour: StormSetupUTC.calendar.component(.hour, from: self)
            )
        ) ?? self
    }
}
