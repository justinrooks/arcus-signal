@testable import App
import Foundation
import Testing
import SwiftyH3

@Suite("Anvil profile preview provider", .serialized)
struct AnvilProfilePreviewProviderTests {
    @Test("provider falls back to the next HRRR candidate when the first candidate fails")
    func providerFallsBackAcrossCandidates() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell)
        let firstCandidate = HrrrRunCandidate(runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let secondCandidate = HrrrRunCandidate(runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21), forecastHour: 1)
        let resolver = PreviewStaticHrrrRunResolver(
            resolution: HrrrRunResolution(
                targetValidTime: now.truncatedToHour,
                candidates: [firstCandidate, secondCandidate]
            )
        )
        let dateProvider = PreviewFixedStormSetupDateProvider(nowDate: now)
        let subsetLoader = PreviewStubStormSetupSubsetLoader { callIndex, resolution, centroid in
            #expect(centroid == expected.centroid)

            switch callIndex {
            case 0:
                #expect(resolution.primaryCandidate == makePressureCandidate(from: firstCandidate))
                throw GribSubsetCacheError.unexpectedHTTPStatus(
                    source: makeSourceMetadata(candidate: makePressureCandidate(from: firstCandidate), centroid: centroid),
                    status: 503
                )
            case 1:
                #expect(resolution.primaryCandidate == makePressureCandidate(from: secondCandidate))
                return previewMakeSubsetResult(
                    source: makeSourceMetadata(candidate: makePressureCandidate(from: secondCandidate), centroid: centroid),
                    fetchedAt: now,
                    cacheHit: true
                )
            default:
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "unexpected extra subset-loader call"
                )
            }
        }
        let fieldSampler = PreviewStubStormSetupFieldSampler { subset, centroid in
            #expect(subset.cacheHit == true)
            #expect(centroid == expected.centroid)
            return previewMakePressureSamples(
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
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: dateProvider,
            hrrrRunResolver: resolver,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler
        )

        let preview = try await provider.previewProfile(for: h3Cell)

        #expect(preview.request.location.h3 == h3String(for: h3Cell))
        #expect(preview.debug.product == .wrfprsf)
        #expect(preview.debug.runTime == previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21))
        #expect(preview.debug.forecastHour == 1)
        #expect(preview.debug.validTime == previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
        #expect(preview.debug.h3 == h3String(for: h3Cell))
        #expect(preview.debug.centroid == expected.centroid)
        #expect(preview.debug.subsetCacheHit == true)
        #expect(preview.request.profile.count == 5)
        #expect(preview.debug.pressureLevelsRetained == [1000, 925, 850, 700, 500])
        #expect(preview.debug.warnings.contains(where: { $0.contains("Dropped incomplete pressure levels") }))
    }

    @Test("provider surfaces unusable profile failures when too few levels are retained")
    func providerSurfacesUnusableProfile() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let firstCandidate = HrrrRunCandidate(runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let resolver = PreviewStaticHrrrRunResolver(
            resolution: HrrrRunResolution(
                targetValidTime: now.truncatedToHour,
                candidates: [firstCandidate]
            )
        )
        let dateProvider = PreviewFixedStormSetupDateProvider(nowDate: now)
        let subsetLoader = PreviewStubStormSetupSubsetLoader { _, _, centroid in
            previewMakeSubsetResult(
                source: makeSourceMetadata(candidate: makePressureCandidate(from: firstCandidate), centroid: centroid),
                fetchedAt: now
            )
        }
        let fieldSampler = PreviewStubStormSetupFieldSampler { _, _ in
            previewMakePressureSamples(
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
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: dateProvider,
            hrrrRunResolver: resolver,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the preview provider to fail with unusable profile data.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile = error {
                return
            } else {
                Issue.record("Expected unusable profile error but got \(error).")
            }
        }
    }
}

private func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
    HrrrRunCandidate(
        model: candidate.model,
        product: .wrfprsf,
        domain: candidate.domain,
        runTime: candidate.runTime,
        forecastHour: candidate.forecastHour,
        fieldSetVersion: .tornadoPressureV1
    )
}

private func makeSourceMetadata(candidate: HrrrRunCandidate, centroid: StormSetupCentroid) -> StormSetupSourceMetadata {
    HrrrNomadsURLBuilder().makeSourceMetadata(for: candidate, around: centroid)
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

private func h3String(for h3Cell: Int64) -> String {
    H3Cell(UInt64(bitPattern: h3Cell)).description
}
