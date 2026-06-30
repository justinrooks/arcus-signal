@testable import App
import Foundation
import Testing
import SwiftyH3
import Vapor

@Suite("Anvil profile preview provider", .serialized)
struct AnvilProfilePreviewProviderTests {
    @Test("provider uses ready pressure artifacts without invoking the cold direct-object path")
    func providerUsesReadyPressureArtifactsWithoutInvokingColdPath() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let expectedCentroid = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell).centroid
        let surfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let readyArtifact = previewMakeReadyPressureArtifact(
            runTime: pressureCandidate.runTime,
            forecastHour: pressureCandidate.forecastHour,
            validTime: pressureCandidate.validTime,
            localPath: "/private/tmp/ready-pressure-artifact.grib2",
            byteSize: 2_048
        )
        let lookupService = PreviewStubPressureArtifactCatalogLookupService { lookedUpCandidate in
            #expect(lookedUpCandidate == pressureCandidate)
            return readyArtifact
        }
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            Issue.record("Pressure source resolver should not have been called for a ready pressure artifact.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                Issue.record("Cold pressure profile loading should not have been called for a ready pressure artifact.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
            },
            readyHandler: { artifact, centroid, surfaceHeightMslM in
                #expect(artifact == readyArtifact)
                #expect(centroid == expectedCentroid)
                #expect(surfaceHeightMslM == 1_234)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples(),
                    surfaceHeightMslM: surfaceHeightMslM
                )
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [surfaceCandidate])
            ),
            pressureArtifactCatalogLookupService: lookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        let preview = try await provider.previewProfile(for: h3Cell)
        let lookupCount = await lookupService.callCount

        #expect(lookupCount == 1)
        #expect(preview.request.runTime == readyArtifact.runTime)
        #expect(preview.request.forecastHour == readyArtifact.forecastHour)
        #expect(preview.request.validTime == readyArtifact.validTime)
        #expect(preview.debug.primaryDownloadURL == readyArtifact.localFileURL)
        #expect(preview.debug.idxURL == nil)
        #expect(preview.debug.idxAvailable == nil)
        #expect(preview.debug.gribAvailable == nil)
        #expect(preview.debug.selectedPressureLevels == [925, 850, 700, 600, 500, 400, 300])
        #expect(preview.request.profile.pressureMb == [940, 925, 850, 700, 600, 500, 400, 300])
    }

    @Test("provider prefers exact ready artifacts before stale fallback")
    func providerPrefersExactReadyArtifactsBeforeStaleFallback() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let expectedCentroid = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell).centroid
        let firstCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let secondCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
            forecastHour: 1
        )
        let firstPressureCandidate = makePressureCandidate(from: firstCandidate)
        let secondPressureCandidate = makePressureCandidate(from: secondCandidate)
        let exactArtifact = previewMakeReadyPressureArtifact(
            runTime: secondPressureCandidate.runTime,
            forecastHour: secondPressureCandidate.forecastHour,
            validTime: secondPressureCandidate.validTime,
            localPath: "/private/tmp/exact-ready-pressure-artifact.grib2",
            byteSize: 2_048
        )
        let staleArtifact = previewMakeReadyPressureArtifact(
            runTime: firstPressureCandidate.runTime,
            forecastHour: firstPressureCandidate.forecastHour,
            validTime: firstPressureCandidate.validTime,
            localPath: "/private/tmp/stale-ready-pressure-artifact.grib2",
            byteSize: 2_048,
            freshness: .stale(ageSeconds: 3_600)
        )
        let lookupService = PreviewStubPressureArtifactCatalogLookupService(
            handler: { lookedUpCandidate in
                if lookedUpCandidate == firstPressureCandidate {
                    return nil
                }
                if lookedUpCandidate == secondPressureCandidate {
                    return exactArtifact
                }
                Issue.record("Unexpected exact lookup candidate \(lookedUpCandidate.fileName).")
                return nil
            },
            staleHandler: { _ in
                Issue.record("Stale lookup should not have been used when an exact artifact exists.")
                return staleArtifact
            }
        )
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            Issue.record("Pressure source resolver should not have been called for exact ready artifacts.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                Issue.record("Cold pressure profile loading should not have been called for exact ready artifacts.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
            },
            readyHandler: { artifact, centroid, surfaceHeightMslM in
                #expect(artifact == exactArtifact)
                #expect(centroid == expectedCentroid)
                #expect(surfaceHeightMslM == 1_234)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples(),
                    surfaceHeightMslM: surfaceHeightMslM
                )
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [firstCandidate, secondCandidate])
            ),
            pressureArtifactCatalogLookupService: lookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        let preview = try await provider.previewProfile(for: h3Cell)
        let lookupCount = await lookupService.callCount
        let staleLookupCount = await lookupService.staleCallCount

        #expect(lookupCount == 2)
        #expect(staleLookupCount == 0)
        #expect(preview.request.runTime == exactArtifact.runTime)
        #expect(preview.request.forecastHour == exactArtifact.forecastHour)
        #expect(preview.request.validTime == exactArtifact.validTime)
        #expect(preview.debug.warnings.contains(where: { $0.contains("stale fallback selected") }) == false)
        #expect(preview.request.profile.pressureMb == [940, 925, 850, 700, 600, 500, 400, 300])
    }

    @Test("provider uses stale pressure artifacts only after all exact candidates miss")
    func providerUsesStalePressureArtifactsOnlyAfterAllExactCandidatesMiss() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let expectedCentroid = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell).centroid
        let surfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let staleArtifact = previewMakeReadyPressureArtifact(
            runTime: pressureCandidate.runTime.addingTimeInterval(-3_600),
            forecastHour: 0,
            validTime: pressureCandidate.runTime.addingTimeInterval(-3_600),
            localPath: "/private/tmp/stale-pressure-artifact.grib2",
            byteSize: 2_048,
            freshness: .stale(ageSeconds: 3_600)
        )
        let staleWarning = "Pressure artifact stale fallback selected: 3600s older than target valid time 2026-06-03T22:00:00Z."
        let lookupService = PreviewStubPressureArtifactCatalogLookupService(
            handler: { _ in nil },
            staleHandler: { resolution in
                #expect(resolution.targetValidTime == now.truncatedToHour)
                return staleArtifact
            }
        )
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            Issue.record("Pressure source resolver should not have been called for stale ready artifacts.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                Issue.record("Cold pressure profile loading should not have been called for stale ready artifacts.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
            },
            readyHandler: { artifact, centroid, surfaceHeightMslM in
                #expect(artifact == staleArtifact)
                #expect(artifact.freshness == .stale(ageSeconds: 3_600))
                #expect(centroid == expectedCentroid)
                #expect(surfaceHeightMslM == 1_234)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples(),
                    surfaceHeightMslM: surfaceHeightMslM
                )
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [surfaceCandidate])
            ),
            pressureArtifactCatalogLookupService: lookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        let preview = try await provider.previewProfile(for: h3Cell)
        let lookupCount = await lookupService.callCount
        let staleLookupCount = await lookupService.staleCallCount

        #expect(lookupCount == 1)
        #expect(staleLookupCount == 1)
        #expect(preview.request.runTime == staleArtifact.runTime)
        #expect(preview.request.forecastHour == staleArtifact.forecastHour)
        #expect(preview.request.validTime == staleArtifact.validTime)
        #expect(preview.debug.warnings.contains(staleWarning))
        #expect(preview.request.profile.pressureMb == [940, 925, 850, 700, 600, 500, 400, 300])
    }

    @Test("provider reports ready-artifact pressure evidence as unavailable when no catalog row is ready")
    func providerReportsReadyArtifactPressureEvidenceAsUnavailableWhenNoRowIsReady() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let surfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let lookupService = PreviewStubPressureArtifactCatalogLookupService { lookedUpCandidate in
            #expect(lookedUpCandidate == pressureCandidate)
            return nil
        }
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            Issue.record("Pressure source resolver should not have been called when no ready artifact exists.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                Issue.record("Pressure profile loader should not have been called when no ready artifact exists.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [surfaceCandidate])
            ),
            pressureArtifactCatalogLookupService: lookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the preview provider to report a missing ready artifact.")
        } catch let error as AnvilProfilePreviewError {
            if case .upstreamUnavailable(let reason) = error {
                #expect(reason.contains("No ready or stale pressure artifact was available") == true)
                let lookupCount = await lookupService.callCount
                #expect(lookupCount == 1)
                return
            }
            Issue.record("Expected upstream unavailable error but got \(error).")
        }
    }

    @Test("provider preserves unusable-profile errors when an exact artifact exists")
    func providerPreservesUnusableProfileErrorsWhenAnExactArtifactExists() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let surfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let exactArtifact = previewMakeReadyPressureArtifact(
            runTime: pressureCandidate.runTime,
            forecastHour: pressureCandidate.forecastHour,
            validTime: pressureCandidate.validTime
        )
        let lookupService = PreviewStubPressureArtifactCatalogLookupService { lookedUpCandidate in
            #expect(lookedUpCandidate == pressureCandidate)
            return exactArtifact
        }
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            Issue.record("Pressure source resolver should not have been called when an exact artifact exists.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected cold-path call")
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                throw AnvilProfilePreviewError.unusableProfile(
                    reason: "No retained levels were available. Missing or dropped pressure levels were not reported."
                )
            },
            readyHandler: { _, _, _ in
                throw AnvilProfilePreviewError.unusableProfile(
                    reason: "No retained levels were available. Missing or dropped pressure levels were not reported."
                )
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [surfaceCandidate])
            ),
            pressureArtifactCatalogLookupService: lookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the preview provider to report an unusable profile.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile(let reason) = error {
                #expect(reason.contains("No retained levels were available") == true)
                let lookupCount = await lookupService.callCount
                #expect(lookupCount == 1)
                return
            }
            Issue.record("Expected unusable profile error but got \(error).")
        }
    }

    @Test("provider stops before pressure work when the surface source is unavailable")
    func providerStopsBeforePressureWorkWhenSurfaceSourceIsUnavailable() async throws {
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let surfaceProfileLoader = PreviewStubSurfaceProfileLoader { _, resolution, _ in
            guard let candidate = resolution.candidates.first else {
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "missing surface candidate"
                )
            }

            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "AWS surface object unavailable for \(candidate.fileName)."
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, _, _, _ in
            Issue.record("Pressure profile loading should not have been reached after surface loading failed.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected pressure load")
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: resolver,
            surfaceProfileLoader: surfaceProfileLoader,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the surface lookup failure to stop the preview before pressure work.")
        } catch let error as AnvilProfilePreviewError {
            if case .upstreamUnavailable(let reason) = error {
                #expect(reason.contains("AWS surface object unavailable for hrrr.t21z.wrfprsf01.grib2."))
                #expect(await pressureProfileLoader.callCount == 0)
                #expect(await pressureSourceResolver.callCount == 1)
                return
            }
            Issue.record("Expected upstream unavailable error but got \(error).")
        }
    }

    @Test("provider propagates cancellation instead of trying another candidate")
    func providerPropagatesCancellationInsteadOfTryingAnotherCandidate() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let firstCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let secondCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
            forecastHour: 1
        )
        let pressureSourceResolver = PreviewStubPressureSourceResolver { callIndex, resolution in
            guard let candidate = resolution.candidates.first else {
                throw AnvilProfilePreviewError.internalExecutionFailure(reason: "missing pressure candidate")
            }

            if callIndex == 0 {
                throw CancellationError()
            }

            return previewMakePressureSourceResolution(
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader(
            handler: { _, _, _, _ in
                Issue.record("Pressure profile loading should not have been reached after cancellation.")
                throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected call")
            }
        )
        let provider = DefaultAnvilProfilePreviewProvider(
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: now.truncatedToHour, candidates: [firstCandidate, secondCandidate])
            ),
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        await #expect(throws: CancellationError.self) {
            _ = try await provider.previewProfile(for: h3Cell)
        }

        #expect(await pressureSourceResolver.callCount == 1)
        #expect(await pressureProfileLoader.callCount == 0)
    }

    @Test("provider filters below-ground pressure levels before assembling the Anvil request")
    func providerFiltersBelowGroundPressureLevels() async throws {
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _, surfaceHeightMslM in
            #expect(surfaceHeightMslM == 1_234)
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
                ) + previewMakePressureSamples(
                    level: 600,
                    hgt: 4100,
                    tmp: 275.85,
                    dpt: 266.75,
                    ugrd: -15.25,
                    vgrd: 18.4
                ) + previewMakePressureSamples(
                    level: 500,
                    hgt: 5600,
                    tmp: 268.95,
                    dpt: 261.15,
                    ugrd: -18.75,
                    vgrd: 22.0
                ) + previewMakePressureSamples(
                    level: 400,
                    hgt: 7100,
                    tmp: 258.75,
                    dpt: 252.35,
                    ugrd: -23.5,
                    vgrd: 27.8
                ) + previewMakePressureSamples(
                    level: 300,
                    hgt: 9300,
                    tmp: 246.15,
                    dpt: 240.35,
                    ugrd: -28.9,
                    vgrd: 31.4
                ),
                surfaceHeightMslM: surfaceHeightMslM
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
            pressureProfileLoader: pressureProfileLoader,
            surfaceHeightMslM: 1200
        )

        let preview = try await provider.previewProfile(for: h3Cell)

        #expect(preview.request.profile.pressureMb == [940, 925, 850, 700, 600, 500, 400, 300])
        #expect(preview.debug.pressureLevelsRetained == [925, 850, 700, 600, 500, 400, 300])
        #expect(preview.debug.warnings.contains(where: { $0.contains("Dropped below-ground pressure levels") }))
        #expect(preview.debug.warnings.contains(where: { $0.contains("1000 mb below selected surface height 1234.0m") }))
    }

    @Test("provider ignores a missing caller surface height and still loads exact-cycle surface data")
    func providerIgnoresMissingCallerSurfaceHeightAndStillLoadsExactCycleSurfaceData() async throws {
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _, surfaceHeightMslM in
            #expect(surfaceHeightMslM == 1_234)
            return previewMakePressureProfileLoadResult(
                sourceResolution: sourceResolution,
                fetchedAt: now,
                samples: previewMakeEightLevelPressureSamples(),
                surfaceHeightMslM: surfaceHeightMslM
            )
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: resolver,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )

        let preview = try await provider.previewProfile(for: h3Cell)

        #expect(preview.request.profile.pressureMb == [940, 925, 850, 700, 600, 500, 400, 300])
    }

    @Test("provider rejects mismatched exact-cycle surface data before pressure loading")
    func providerRejectsMismatchedExactCycleSurfaceDataBeforePressureLoading() async throws {
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _, surfaceHeightMslM in
            Issue.record("Pressure profile loading should not have been reached after mismatched surface data.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected pressure load")
        }
        let surfaceProfileLoader = PreviewStubSurfaceProfileLoader { _, resolution, centroid in
            let mismatchCandidate = HrrrRunCandidate(
                runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                forecastHour: 1
            )
            return previewMakeSurfaceProfileLoadResult(
                sourceResolution: HrrrRunResolution(
                    targetValidTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                    candidates: [mismatchCandidate]
                ),
                fetchedAt: now,
                samples: previewMakeSurfaceSamples()
            )
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: resolver,
            surfaceProfileLoader: surfaceProfileLoader,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader,
            surfaceHeightMslM: Double.infinity
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected mismatched exact-cycle surface data to fail.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile(let reason) = error {
                #expect(reason.contains("Matching surface source identity"))
                return
            }
            Issue.record("Expected unusable profile error but got \(error).")
        }
    }

    @Test("provider surfaces an unusable profile when filtering leaves too few above-ground levels")
    func providerSurfacesUnusableProfileAfterFiltering() async throws {
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _, surfaceHeightMslM in
            #expect(surfaceHeightMslM == 2_450)
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
                ) + previewMakePressureSamples(
                    level: 600,
                    hgt: 4100,
                    tmp: 275.85,
                    dpt: 266.75,
                    ugrd: -15.25,
                    vgrd: 18.4
                ) + previewMakePressureSamples(
                    level: 500,
                    hgt: 5600,
                    tmp: 268.95,
                    dpt: 261.15,
                    ugrd: -18.75,
                    vgrd: 22.0
                ) + previewMakePressureSamples(
                    level: 400,
                    hgt: 7100,
                    tmp: 258.75,
                    dpt: 252.35,
                    ugrd: -23.5,
                    vgrd: 27.8
                ) + previewMakePressureSamples(
                    level: 300,
                    hgt: 9300,
                    tmp: 246.15,
                    dpt: 240.35,
                    ugrd: -28.9,
                    vgrd: 31.4
                ),
                surfaceHeightMslM: surfaceHeightMslM
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
        let surfaceProfileLoader = PreviewStubSurfaceProfileLoader { _, resolution, centroid in
            let surfaceCandidate = resolution.candidates.first ?? HrrrRunCandidate(
                runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 0
            )
            return previewMakeSurfaceProfileLoadResult(
                sourceResolution: HrrrRunResolution(
                    targetValidTime: resolution.targetValidTime,
                    candidates: [HrrrRunCandidate(
                        model: surfaceCandidate.model,
                        product: .wrfsfc,
                        domain: surfaceCandidate.domain,
                        runTime: surfaceCandidate.runTime,
                        forecastHour: surfaceCandidate.forecastHour,
                        fieldSetVersion: .anvilSurfaceV1
                    )]
                ),
                fetchedAt: now,
                samples: previewMakeSurfaceSamples(
                    heightMslM: 2_450
                )
            )
        }

        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: PreviewFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: resolver,
            surfaceProfileLoader: surfaceProfileLoader,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader,
            surfaceHeightMslM: 2450
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected the preview provider to reject the filtered profile.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile(let reason) = error {
                #expect(reason.contains("Only 4 retained levels were available"))
                #expect(reason.contains("Below-ground levels"))
                #expect(reason.contains("1000 mb below selected surface height 2450.0m"))
                return
            }
            Issue.record("Expected unusable profile error but got \(error).")
        }
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
                candidate: candidate,
                idxAvailable: true
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, _, _ in
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
                ),
                surfaceHeightMslM: 1_234
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
                #expect(reason.contains("Only 3 retained levels"))
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
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _, _ in
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
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _, _ in
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
                    candidate: candidate,
                    idxAvailable: true
                )
            },
            pressureProfileLoader: PreviewStubPressureProfileLoader { _, _, _, _ in
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

private func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
    let runTime = StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: candidate.runTime) ?? candidate.runTime
    return HrrrRunCandidate(
        model: candidate.model,
        product: .wrfprsf,
        domain: candidate.domain,
        runTime: runTime,
        forecastHour: candidate.forecastHour + 1,
        fieldSetVersion: HrrrProduct.wrfprsf.defaultFieldSetVersion
    )
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
