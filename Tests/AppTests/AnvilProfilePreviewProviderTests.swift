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
        let pressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: surfaceCandidate.runTime,
            forecastHour: surfaceCandidate.forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
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
                #expect(surfaceHeightMslM == nil)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples()
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
        #expect(preview.debug.selectedPressureLevels == [1000, 925, 850, 700, 600, 500, 400, 300])
        #expect(preview.request.profile.pressureMb == [1000, 925, 850, 700, 600, 500, 400, 300])
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
        let firstPressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: firstCandidate.runTime,
            forecastHour: firstCandidate.forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
        let secondPressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: secondCandidate.runTime,
            forecastHour: secondCandidate.forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
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
            validTime: firstPressureCandidate.validTime.addingTimeInterval(-3_600),
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
                #expect(surfaceHeightMslM == nil)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples()
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
        let pressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: surfaceCandidate.runTime,
            forecastHour: surfaceCandidate.forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
        let staleArtifact = previewMakeReadyPressureArtifact(
            runTime: pressureCandidate.runTime.addingTimeInterval(-3_600),
            forecastHour: 0,
            validTime: pressureCandidate.validTime.addingTimeInterval(-3_600),
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
                #expect(surfaceHeightMslM == nil)
                return previewMakeReadyPressureProfileLoadResult(
                    readyArtifact: artifact,
                    fetchedAt: now,
                    subsetCacheHit: true,
                    samples: previewMakeEightLevelPressureSamples()
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
    }

    @Test("provider reports ready-artifact pressure evidence as unavailable when no catalog row is ready")
    func providerReportsReadyArtifactPressureEvidenceAsUnavailableWhenNoRowIsReady() async throws {
        let now = previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let surfaceCandidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let pressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: surfaceCandidate.runTime,
            forecastHour: surfaceCandidate.forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
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
                    candidate: candidate,
                    idxAvailable: true
                )
            default:
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: "unexpected extra source-resolution call"
                )
            }
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { callIndex, sourceResolution, centroid, surfaceHeightMslM in
            #expect(callIndex == 0)
            #expect(sourceResolution.idxProbe.available == true)
            #expect(centroid == expected.centroid)
            #expect(surfaceHeightMslM == nil)
            return previewMakePressureProfileLoadResult(
                sourceResolution: sourceResolution,
                fetchedAt: now,
                subsetCacheHit: true,
                samples: previewMakeEightLevelPressureSamples()
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
        let expectedGrouping = StormSetupPressureProfileGrouper().group(
            samples: previewMakeEightLevelPressureSamples()
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
        #expect(preview.debug.h3 == H3Cell(UInt64(bitPattern: expected.h3Cell)).description)
        #expect(preview.debug.centroid == expected.centroid)
        #expect(preview.debug.selectedMessageCount == 5)
        #expect(preview.debug.selectedPressureLevels == [1000])
        #expect(preview.debug.rangeCount == 5)
        #expect(preview.debug.totalSelectedRangeBytes == 1024)
        #expect(preview.debug.pressureLevelsRequested == [1000])
        #expect(preview.debug.subsetCacheHit == true)
        #expect(preview.debug.primaryDownloadURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260603/conus/hrrr.t21z.wrfprsf01.grib2")
        #expect(preview.debug.idxURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260603/conus/hrrr.t21z.wrfprsf01.grib2.idx")
        #expect(preview.debug.idxAvailable == true)
        #expect(preview.debug.gribAvailable == nil)
        #expect(preview.debug.pressureLevelsRetained == [1000, 925, 850, 700, 600, 500, 400, 300])
        #expect(preview.debug.missingLevels.isEmpty)
        #expect(preview.debug.warnings.contains(where: { $0.contains("Dropped incomplete pressure levels") }))
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

        #expect(preview.request.profile.pressureMb == [925, 850, 700, 600, 500, 400, 300])
        #expect(preview.debug.pressureLevelsRetained == [925, 850, 700, 600, 500, 400, 300])
        #expect(preview.debug.warnings.contains(where: { $0.contains("Dropped below-ground pressure levels") }))
        #expect(preview.debug.warnings.contains(where: { $0.contains("1000 mb below selected surface height 1200.0m") }))
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
    candidate
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
