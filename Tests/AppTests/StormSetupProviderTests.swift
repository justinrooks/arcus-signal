@testable import App
import Foundation
import Logging
import Testing
import ArcusCore

@Suite("Storm setup provider orchestration", .serialized)
struct StormSetupProviderTests {
    @Test("sampled snapshot cache is checked before re-running downstream work")
    func snapshotCacheHitSkipsSubsetAndSampling() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let cachedSnapshot = makeSnapshot(
            h3Cell: fixedH3,
            source: makeSourceMetadata(
                candidate: HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0),
                centroid: expected.centroid
            ),
            fetchedAt: now,
            raw: makeRaw(sbcapeJkg: 1450),
            assessment: makeAssessment(),
            freshness: makeFreshness(now: now)
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: cachedSnapshot)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            throw TestFailure.unexpectedDownstreamCall("subset loader should not run on a cache hit")
        }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw TestFailure.unexpectedDownstreamCall("field sampler should not run on a cache hit")
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: StubStormSetupAssessor(assessment: makeAssessment())
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount

        #expect(snapshot.h3Cell == fixedH3)
        #expect(snapshot.raw.sbcapeJkg == 1450)
        #expect(snapshot.anvilEvidence == nil)
        #expect(snapshot.assessment.overall == .conditional)
        #expect(snapshot.assessment.confidence == .moderate)
        #expect(loadCount == 1)
        #expect(storeCount == 0)
        #expect(subsetRequestCount == 0)
        #expect(fieldSampleRequestCount == 0)
    }

    @Test("current response includes composed setup ingredients and raw Anvil analysis when exact")
    func currentResponseIncludesRawAnvilAnalysisWhenExact() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in subset }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let expectedAnalysis = makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime).response
        let anvilProvider = CountingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime)
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                temperature2mK: 295.15,
                dewpoint2mK: 289.15,
                surfacePressurePa: 94_000,
                wind10m: DirectionSpeed(directionDegrees: 69.8, speedKt: 39.2),
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            ))),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let response = try await provider.currentResponse(for: fixedH3)

        #expect(response.setup.h3Cell == fixedH3)
        #expect(response.ingredients.canonical.mucapeJkg == 362.1018454649957)
        #expect(response.ingredients.canonical.sbcapeJkg == 1450)
        #expect(response.ingredients.canonical.mlcapeJkg == 191.7304143918497)
        #expect(response.ingredients.canonical.mlcinJkg == -221.93726424748172)
        #expect(response.ingredients.canonical.mllclM == 1179.4130766012365)
        #expect(response.ingredients.canonical.effectiveBulkShearMs == 30.134722226263612)
        #expect(response.ingredients.canonical.effectiveLayer?.status == "found")
        #expect(response.ingredients.canonical.stormMotion?.status == "computed")
        #expect(response.ingredients.canonical.ship == 2.3)
        #expect(response.profileAnalysis?.ship == 2.3)
        #expect(response.ingredients.diagnostics.sbcapeJkg == 1450)
        #expect(response.ingredients.diagnostics.temperature2mK == 295.15)
        #expect(response.ingredients.diagnostics.dewpoint2mK == 289.15)
        #expect(response.ingredients.diagnostics.surfacePressurePa == 94_000)
        #expect(response.profileAnalysis == expectedAnalysis)
        #expect(response.tornadoViability.overall == .weak)
        #expect(response.tornadoViability.confidence == .high)
        #expect(await anvilProvider.requestCount == 1)
    }

    @Test("current response omits raw Anvil analysis when the provider rejects it")
    func currentResponseOmitsRawAnvilAnalysisWhenRejected() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in subset }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                )
            ]
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                temperature2mK: 295.15,
                dewpoint2mK: 289.15,
                surfacePressurePa: 94_000,
                wind10m: DirectionSpeed(directionDegrees: 69.8, speedKt: 39.2),
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            ))),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: ThrowingAnvilProfileAnalysisProvider(error: TestFailure.unexpectedDownstreamCall("Anvil offline"))
        )

        let response = try await provider.currentResponse(for: fixedH3)

        #expect(response.profileAnalysis == nil)
        #expect(response.ingredients.canonical == response.ingredients.diagnostics)
        #expect(response.tornadoViability.overall == .conditional)
        #expect(response.tornadoViability.confidence == .low)
        #expect(response.tornadoViability.summary.contains("Anvil analysis is unavailable, so confidence is limited."))
    }

    @Test("current response keeps surface ingredients when the provider only has stale Anvil analysis")
    func currentResponseKeepsSurfaceIngredientsWhenAnvilIsStale() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)
        let staleWarning = "Pressure artifact stale fallback selected: 3600s older than target valid time 2026-06-03T22:00:00Z."

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in subset }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let staleAnalysis = makeStormSetupRouteAnalysisResponse(
            validTime: candidate.validTime.addingTimeInterval(-3_600),
            warnings: [staleWarning]
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                temperature2mK: 295.15,
                dewpoint2mK: 289.15,
                surfacePressurePa: 94_000,
                wind10m: DirectionSpeed(directionDegrees: 69.8, speedKt: 39.2),
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            ))),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StubAnvilProfileAnalysisProvider(response: staleAnalysis)
        )

        let response = try await provider.currentResponse(for: fixedH3)

        #expect(response.profileAnalysis == nil)
        #expect(response.ingredients.canonical.mucapeJkg == 1600)
        #expect(response.ingredients.canonical.mlcapeJkg == 1200)
        #expect(response.ingredients.canonical.mllclM == 950)
        #expect(response.ingredients.canonical.effectiveLayer == nil)
        #expect(response.tornadoViability.confidence == .low)
        #expect(response.tornadoViability.summary.contains("Anvil analysis is degraded, so confidence is limited."))
    }

    @Test("cache hits refresh Anvil evidence when the provider is configured")
    func snapshotCacheHitRefreshesAnvilEvidence() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let freshness = makeFreshness(now: now)
        let raw = makeRaw(
            sbcapeJkg: 1450,
            mlcapeJkg: 1200,
            mucapeJkg: 1600,
            mlcinJkg: -35,
            mllclM: 950,
            shear06kmKt: 42,
            srh01kmM2s2: 80,
            srh03kmM2s2: 160
        )
        let staleEvidence = AnvilIngredientEvidence.unavailable(reason: "Cached Anvil evidence is stale.")
        let cachedSnapshot = makeSnapshot(
            h3Cell: fixedH3,
            source: source,
            fetchedAt: now,
            raw: raw,
            assessment: TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness, evidence: staleEvidence),
            freshness: freshness,
            anvilEvidence: staleEvidence
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: cachedSnapshot)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            throw TestFailure.unexpectedDownstreamCall("subset loader should not run on a cache hit")
        }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw TestFailure.unexpectedDownstreamCall("field sampler should not run on a cache hit")
        }
        let anvilProvider = CountingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime)
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount
        let anvilRequestCount = await anvilProvider.requestCount

        #expect(snapshot.anvilEvidence?.status == .available)
        #expect(snapshot.anvilEvidence?.reason == nil)
        #expect(snapshot.assessment.overall == .weak)
        #expect(snapshot.assessment.confidence == .high)
        #expect(snapshot.assessment.summary.contains("Anvil analysis reinforces the setup.") == false)
        #expect(loadCount == 1)
        #expect(storeCount == 0)
        #expect(subsetRequestCount == 0)
        #expect(fieldSampleRequestCount == 0)
        #expect(anvilRequestCount == 1)
    }

    @Test("runtime snapshot handoff forwards the selected surface height into Anvil analysis")
    func runtimeSnapshotHandoffForwardsSelectedSurfaceHeight() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            makeSubsetResult(source: source, fetchedAt: now)
        }
        let fieldSampler = StubStormSetupFieldSampler { _, centroid in
            [
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:HGT:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1234"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: centroid.longitude,
                    requestedLatitude: centroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "6:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let anvilProvider = CapturingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse()
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: TornadoIngredientNormalizer(),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.surfaceHeightMslM == 1234)
        #expect(snapshot.anvilEvidence?.status == .available)
        #expect(await anvilProvider.requestCount == 1)
    }

    @Test("cancellation during Anvil composition stops candidate fallback")
    func cancellationDuringAnvilCompositionStopsCandidateFallback() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let firstCandidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: firstCandidate, centroid: expected.centroid)
        let freshness = makeFreshness(now: now)
        let raw = makeRaw(sbcapeJkg: 1450)
        let cachedSnapshot = makeSnapshot(
            h3Cell: fixedH3,
            source: source,
            fetchedAt: now,
            raw: raw,
            assessment: makeAssessment(),
            freshness: freshness
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: cachedSnapshot)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            throw TestFailure.unexpectedDownstreamCall("subset loader should not run on a cache hit")
        }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw TestFailure.unexpectedDownstreamCall("field sampler should not run on a cache hit")
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: ThrowingAnvilProfileAnalysisProvider(error: CancellationError())
        )

        await #expect(throws: CancellationError.self) {
            _ = try await provider.currentSnapshot(for: fixedH3)
        }

        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount

        #expect(loadCount == 1)
        #expect(storeCount == 0)
        #expect(subsetRequestCount == 0)
        #expect(fieldSampleRequestCount == 0)
    }

    @Test("stale Anvil evidence is marked degraded while retaining metric support")
    func snapshotCacheHitMarksStaleAnvilEvidenceDegraded() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let freshness = makeFreshness(now: now)
        let raw = makeRaw(
            sbcapeJkg: 1450,
            mlcapeJkg: 1200,
            mucapeJkg: 1600,
            mlcinJkg: -35,
            mllclM: 950,
            shear06kmKt: 42,
            srh01kmM2s2: 80,
            srh03kmM2s2: 160
        )
        let staleWarning = "Pressure artifact stale fallback selected: 3600s older than target valid time 2026-06-03T22:00:00Z."
        let cachedSnapshot = makeSnapshot(
            h3Cell: fixedH3,
            source: source,
            fetchedAt: now,
            raw: raw,
            assessment: TornadoIngredientInterpreter().assess(
                raw: raw,
                freshness: freshness,
                evidence: AnvilIngredientEvidence(
                    response: makeStormSetupRouteAnalysisResponse(
                        validTime: candidate.validTime.addingTimeInterval(-3_600),
                        warnings: [staleWarning]
                    ).response,
                    additionalWarnings: [staleWarning]
                )
            ),
            freshness: freshness,
            anvilEvidence: AnvilIngredientEvidence(
                response: makeStormSetupRouteAnalysisResponse(
                    validTime: candidate.validTime.addingTimeInterval(-3_600),
                    warnings: [staleWarning]
                ).response,
                additionalWarnings: [staleWarning]
            )
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: cachedSnapshot)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            throw TestFailure.unexpectedDownstreamCall("subset loader should not run on a cache hit")
        }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw TestFailure.unexpectedDownstreamCall("field sampler should not run on a cache hit")
        }
        let anvilProvider = CountingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse(
                validTime: candidate.validTime.addingTimeInterval(-3_600),
                warnings: [staleWarning]
            )
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.anvilEvidence?.status == .degraded)
        #expect(snapshot.anvilEvidence?.diagnostics.warnings.contains(staleWarning) == true)
        #expect(snapshot.anvilEvidence?.scp?.support == .strong)
        #expect(snapshot.anvilEvidence?.stp?.support == .strong)
        #expect(snapshot.anvilEvidence?.ship?.support == .strong)
        #expect(snapshot.anvilEvidence?.strongestSupport == .strong)
    }

    @Test("cache hits ignore stale Anvil evidence when the current provider changes")
    func snapshotCacheHitIgnoresStaleAnvilEvidence() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let candidate = HrrrRunCandidate(
            runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0
        )
        let source = makeSourceMetadata(candidate: candidate, centroid: expected.centroid)
        let freshness = makeFreshness(now: now)
        let raw = makeRaw(
            sbcapeJkg: 1450,
            mlcapeJkg: 1200,
            mucapeJkg: 1600,
            mlcinJkg: -35,
            mllclM: 950,
            shear06kmKt: 42,
            srh01kmM2s2: 80,
            srh03kmM2s2: 160
        )
        let cachedEvidence = AnvilIngredientEvidence(
            response: makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime).response
        )
        let cachedSnapshot = makeSnapshot(
            h3Cell: fixedH3,
            source: source,
            fetchedAt: now,
            raw: raw,
            assessment: TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness, evidence: cachedEvidence),
            freshness: freshness,
            anvilEvidence: cachedEvidence
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: cachedSnapshot)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in
            throw TestFailure.unexpectedDownstreamCall("subset loader should not run on a cache hit")
        }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw TestFailure.unexpectedDownstreamCall("field sampler should not run on a cache hit")
        }
        let anvilProvider = CountingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime.addingTimeInterval(3_600))
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let anvilRequestCount = await anvilProvider.requestCount

        #expect(snapshot.anvilEvidence?.status == .unavailable)
        #expect(snapshot.anvilEvidence?.reason?.contains("selected surface HRRR valid time") == true)
        #expect(anvilRequestCount == 1)
    }

    @Test("provider fetches a GRIB subset on snapshot cache miss and stores the sampled snapshot")
    func cacheMissFetchesSubsetAndStoresSnapshot() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let candidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let source = makeSourceMetadata(candidate: candidate, centroid: centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(callIndex == 0)
            #expect(resolution.primaryCandidate == candidate)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return subset
        }
        let fieldSampler = StubStormSetupFieldSampler { loadedSubset, requestCentroid in
            #expect(loadedSubset.localFileURL == subset.localFileURL)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                )
            ]
        }
        let normalized = makeNormalizationResult(
            raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            )
        )
        let anvilProvider = CountingAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse(validTime: candidate.validTime)
        )
        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: anvilProvider
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount
        let anvilRequestCount = await anvilProvider.requestCount

        #expect(snapshot.source.runTime == candidate.runTime)
        #expect(snapshot.source.forecastHour == candidate.forecastHour)
        #expect(snapshot.raw.sbcapeJkg == 1450)
        #expect(snapshot.canonicalIngredients.ship == 2.3)
        #expect(snapshot.anvilEvidence?.status == .available)
        #expect(snapshot.anvilEvidence?.reason == nil)
        #expect(loadCount == 1)
        #expect(storeCount == 1)
        #expect(subsetRequestCount == 1)
        #expect(fieldSampleRequestCount == 1)
        #expect(anvilRequestCount == 1)
    }

    @Test("provider augments the snapshot with Anvil evidence and uses it in the assessment")
    func providerAugmentsSnapshotWithAnvilEvidence() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let candidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let source = makeSourceMetadata(candidate: candidate, centroid: centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(callIndex == 0)
            #expect(resolution.primaryCandidate == candidate)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return subset
        }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let normalized = makeNormalizationResult(
            raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            )
        )
        let anvilResponse = makeStormSetupRouteAnalysisResponse(
            validTime: candidate.validTime
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StubAnvilProfileAnalysisProvider(response: anvilResponse)
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.anvilEvidence?.status == .available)
        #expect(snapshot.anvilEvidence?.scp?.support == .strong)
        #expect(snapshot.anvilEvidence?.stp?.support == .strong)
        #expect(snapshot.anvilEvidence?.ship?.support == .strong)
        #expect(snapshot.assessment.summary.contains("Anvil analysis reinforces the setup.") == false)
    }

    @Test("provider rejects Anvil evidence when its valid time does not match the selected surface source")
    func providerRejectsMismatchedAnvilEvidenceTiming() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let candidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let source = makeSourceMetadata(candidate: candidate, centroid: centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)
        let anvilResponse = makeStormSetupRouteAnalysisResponse(
            validTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 23)
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(callIndex == 0)
            #expect(resolution.primaryCandidate == candidate)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return subset
        }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let normalized = makeNormalizationResult(
            raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            )
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StubAnvilProfileAnalysisProvider(response: anvilResponse)
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.anvilEvidence?.status == .unavailable)
        #expect(snapshot.anvilEvidence?.reason?.contains("2026-06-03 23:00:00 +0000") == true)
        #expect(snapshot.anvilEvidence?.reason?.contains("2026-06-03 22:00:00 +0000") == true)
        #expect(snapshot.anvilEvidence?.reason?.contains("selected surface HRRR valid time") == true)
        #expect(snapshot.assessment.overall == IngredientSupport.conditional)
        #expect(snapshot.assessment.confidence == .low)
    }

    @Test("provider keeps Anvil evidence aligned with the selected fallback surface source")
    func providerAlignsAnvilEvidenceWithFallbackSurfaceSource() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let firstCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let secondCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 21), forecastHour: 1)
        let firstSource = makeSourceMetadata(candidate: firstCandidate, centroid: centroid)
        let secondSource = makeSourceMetadata(candidate: secondCandidate, centroid: centroid)
        let secondSubset = makeSubsetResult(source: secondSource, fetchedAt: now)
        let anvilResponse = makeStormSetupRouteAnalysisResponse(
            validTime: secondSource.validTime ?? secondCandidate.validTime
        )

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)

            switch callIndex {
            case 0:
                #expect(resolution.primaryCandidate == firstCandidate)
                throw GribSubsetCacheError.unexpectedHTTPStatus(source: firstSource, status: 503)
            case 1:
                #expect(resolution.primaryCandidate == secondCandidate)
                return secondSubset
            default:
                throw TestFailure.unexpectedDownstreamCall("unexpected extra subset-loader call")
            }
        }
        let fieldSampler = StubStormSetupFieldSampler { subset, requestCentroid in
            #expect(subset.localFileURL == secondSubset.localFileURL)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1600"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-30"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=90"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=7"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=9"
                    )
                )
            ]
        }
        let normalized = makeNormalizationResult(
            raw: makeRaw(
                sbcapeJkg: 1600,
                mlcapeJkg: 1300,
                mucapeJkg: 1700,
                mlcinJkg: -30,
                mllclM: 900,
                shear06kmKt: 48,
                srh01kmM2s2: 110,
                srh03kmM2s2: 175
            )
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StubAnvilProfileAnalysisProvider(response: anvilResponse)
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.source.runTime == secondCandidate.runTime)
        #expect(snapshot.source.forecastHour == secondCandidate.forecastHour)
        #expect(snapshot.anvilEvidence?.status == .available)
        #expect(snapshot.anvilEvidence?.reason == nil)
    }

    @Test("provider marks the assessment degraded when Anvil evidence is unavailable")
    func providerMarksAssessmentDegradedWhenAnvilEvidenceIsUnavailable() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let candidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let source = makeSourceMetadata(candidate: candidate, centroid: centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(callIndex == 0)
            #expect(resolution.primaryCandidate == candidate)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return subset
        }
        let fieldSampler = StubStormSetupFieldSampler { _, requestCentroid in
            [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                    )
                ),
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                    )
                )
            ]
        }
        let normalized = makeNormalizationResult(
            raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            )
        )

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: ThrowingAnvilProfileAnalysisProvider(error: TestFailure.unexpectedDownstreamCall("Anvil offline"))
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)

        #expect(snapshot.anvilEvidence?.status == .unavailable)
        #expect(snapshot.anvilEvidence?.reason?.contains("Anvil offline") == true)
        #expect(snapshot.assessment.overall == IngredientSupport.conditional)
        #expect(snapshot.assessment.confidence == .low)
        #expect(snapshot.assessment.summary.contains("Anvil analysis is unavailable, so confidence is limited."))
    }

    @Test("provider falls back to the next HRRR candidate when the first one fails")
    func providerFallsBackToSecondCandidate() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let firstCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let secondCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 21), forecastHour: 1)
        let firstSource = makeSourceMetadata(candidate: firstCandidate, centroid: centroid)
        let secondSource = makeSourceMetadata(candidate: secondCandidate, centroid: centroid)
        let secondSubset = makeSubsetResult(source: secondSource, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)

            switch callIndex {
            case 0:
                #expect(resolution.primaryCandidate == firstCandidate)
                throw GribSubsetCacheError.unexpectedHTTPStatus(source: firstSource, status: 503)
            case 1:
                #expect(resolution.primaryCandidate == secondCandidate)
                return secondSubset
            default:
                throw TestFailure.unexpectedDownstreamCall("unexpected extra subset-loader call")
            }
        }
        let fieldSampler = StubStormSetupFieldSampler { subset, requestCentroid in
            #expect(subset.localFileURL == secondSubset.localFileURL)
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)
            return [
                HrrrFieldSample(
                    requestedLongitude: requestCentroid.longitude,
                    requestedLatitude: requestCentroid.latitude,
                    point: Wgrib2PointSample.parse(
                        from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1600"
                    )
                )
            ]
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(
                result: makeNormalizationResult(
                    raw: makeRaw(
                        sbcapeJkg: 1600,
                        mlcapeJkg: 1700,
                        mucapeJkg: 1800,
                        mlcinJkg: -30,
                        mllclM: 900,
                        shear06kmKt: 48,
                        srh01kmM2s2: 110,
                        srh03kmM2s2: 175
                    )
                )
            ),
            interpreter: StubStormSetupAssessor(assessment: makeAssessment(overall: .supportive))
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount

        #expect(snapshot.source.runTime == secondCandidate.runTime)
        #expect(snapshot.source.forecastHour == secondCandidate.forecastHour)
        #expect(loadCount == 2)
        #expect(storeCount == 1)
        #expect(subsetRequestCount == 2)
        #expect(fieldSampleRequestCount == 1)
    }

    @Test("provider falls back when the first candidate normalizes to no recognizable fields")
    func providerFallsBackToSecondCandidateAfterEmptyNormalization() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let firstCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let secondCandidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 21), forecastHour: 1)
        let firstSource = makeSourceMetadata(candidate: firstCandidate, centroid: centroid)
        let secondSource = makeSourceMetadata(candidate: secondCandidate, centroid: centroid)
        let firstSubset = makeSubsetResult(source: firstSource, fetchedAt: now)
        let secondSubset = makeSubsetResult(source: secondSource, fetchedAt: now)

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { callIndex, resolution, requestCentroid in
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)

            switch callIndex {
            case 0:
                #expect(resolution.primaryCandidate == firstCandidate)
                return firstSubset
            case 1:
                #expect(resolution.primaryCandidate == secondCandidate)
                return secondSubset
            default:
                throw TestFailure.unexpectedDownstreamCall("unexpected extra subset-loader call")
            }
        }
        let fieldSampler = StubStormSetupFieldSampler { subset, requestCentroid in
            #expect(requestCentroid.latitude == centroid.latitude)
            #expect(requestCentroid.longitude == centroid.longitude)

            if subset.localFileURL == firstSubset.localFileURL {
                return [
                    HrrrFieldSample(
                        requestedLongitude: requestCentroid.longitude,
                        requestedLatitude: requestCentroid.latitude,
                        point: Wgrib2PointSample.parse(
                            from: "1:0:d=2026060313:TMP:surface:9 hour fcst:lon=-104.47,lat=39.79,val=12"
                        )
                    )
                ]
            }

            if subset.localFileURL == secondSubset.localFileURL {
                return [
                    HrrrFieldSample(
                        requestedLongitude: requestCentroid.longitude,
                        requestedLatitude: requestCentroid.latitude,
                        point: Wgrib2PointSample.parse(
                            from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1600"
                        )
                    )
                ]
            }

            throw TestFailure.unexpectedDownstreamCall("unexpected subset file URL: \(subset.localFileURL)")
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: TornadoIngredientNormalizer(),
            interpreter: StubStormSetupAssessor(assessment: makeAssessment(overall: .supportive))
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount

        #expect(snapshot.source.runTime == secondCandidate.runTime)
        #expect(snapshot.source.forecastHour == secondCandidate.forecastHour)
        #expect(snapshot.raw.sbcapeJkg == 1600)
        #expect(loadCount == 2)
        #expect(storeCount == 1)
        #expect(subsetRequestCount == 2)
        #expect(fieldSampleRequestCount == 2)
    }

    @Test("known failure modes map to useful HTTP aborts")
    func knownFailuresMapToUsefulAborts() {
        let source = makeSourceMetadata(
            candidate: HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0),
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        )

        let sourceFailure = StormSetupCurrentSnapshotError.noUsableHrrrCandidate([
            StormSetupCurrentSnapshotFailure(
                stage: .gribSubsetCache,
                source: source,
                reason: "NOMADS returned HTTP 503"
            )
        ]).asAbort()
        let wgrib2Failure = StormSetupCurrentSnapshotError.noUsableHrrrCandidate([
            StormSetupCurrentSnapshotFailure(
                stage: .wgrib2Sampling,
                source: source,
                reason: "wgrib2 exited with status 1"
            )
        ]).asAbort()
        let insufficientData = StormSetupCurrentSnapshotError.insufficientNormalizedData(
            source: source,
            reason: "wgrib2 produced no recognizable ingredient values"
        ).asAbort()

        #expect(sourceFailure.status == .serviceUnavailable)
        #expect(wgrib2Failure.status == .internalServerError)
        #expect(insufficientData.status == .unprocessableEntity)
    }

    @Test("wgrib2 executable validation failure is classified as a sampling failure")
    func wgrib2ExecutableValidationFailureIsClassifiedAsSamplingFailure() async throws {
        let now = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let fixedH3: Int64 = 617700169958293503
        let expected = try DefaultStormSetupH3Resolver().resolve(h3Cell: fixedH3)
        let dateProvider = StormSetupRouteDateProvider(nowDate: now)
        let centroid = expected.centroid
        let candidate = HrrrRunCandidate(runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22), forecastHour: 0)
        let source = makeSourceMetadata(candidate: candidate, centroid: centroid)
        let subset = makeSubsetResult(source: source, fetchedAt: now)
        let wgrib2URL = URL(fileURLWithPath: "/tmp/does-not-exist-wgrib2")

        let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
        let subsetLoader = StubStormSetupSubsetLoader { _, _, _ in subset }
        let fieldSampler = StubStormSetupFieldSampler { _, _ in
            throw Wgrib2ClientError.executableMissing(wgrib2URL)
        }

        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: .empty)),
            interpreter: StubStormSetupAssessor(assessment: makeAssessment())
        )

        do {
            _ = try await provider.currentSnapshot(for: fixedH3)
            Issue.record("Expected a no-usable-candidate failure.")
        } catch let error as StormSetupCurrentSnapshotError {
            let abort = error.asAbort()

            guard case .noUsableHrrrCandidate(let failures) = error else {
                Issue.record("Expected noUsableHrrrCandidate, got \(error).")
                return
            }

            #expect(abort.status == .internalServerError)
            #expect(failures.contains(where: { $0.stage == .wgrib2Sampling }))
            #expect(failures.contains(where: { $0.reason.contains("Configured wgrib2 executable does not exist") }))
        }
    }

    private func makeProvider(
        dateProvider: any StormSetupDateProviding,
        snapshotCache: any StormSetupSnapshotCaching,
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling,
        normalizer: any StormSetupIngredientNormalizing,
        interpreter: any StormSetupIngredientAssessing,
        anvilProfileAnalysisProvider: (any AnvilProfileAnalysisProviding)? = nil
    ) -> DefaultStormSetupProvider {
        DefaultStormSetupProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: normalizer,
            interpreter: interpreter,
            anvilProfileAnalysisProvider: anvilProfileAnalysisProvider,
            logger: Logger(label: "storm-setup-tests")
        )
    }

    private func makeSubsetResult(
        source: StormSetupSourceMetadata,
        fetchedAt: Date
    ) -> GribSubsetCacheResult {
        GribSubsetCacheResult(
            source: source,
            localFileURL: URL(fileURLWithPath: "/tmp/arcus-signal-storm-setup-\(UUID().uuidString).grib2"),
            byteSize: 512,
            fetchedAt: fetchedAt,
            expiresAt: fetchedAt.addingTimeInterval(12 * 60 * 60),
            cacheHit: false
        )
    }

    private func makeSourceMetadata(
        candidate: HrrrRunCandidate,
        centroid: StormSetupCentroid
    ) -> StormSetupSourceMetadata {
        HrrrNomadsURLBuilder().makeSourceMetadata(for: candidate, around: centroid)
    }

    private func makeAssessment(overall: IngredientSupport = .conditional) -> TornadoIngredientAssessment {
        TornadoIngredientAssessment(
            overall: overall,
            instability: .supportive,
            moisture: .supportive,
            cloudBase: .supportive,
            capInhibition: .conditional,
            deepShear: .supportive,
            lowLevelRotation: .conditional,
            stormMode: .unknown,
            compositeSignal: .conditional,
            confidence: .moderate,
            trend: .unknown,
            stormModeHint: .unknown,
            primaryDrivers: ["Instability is supportive.", "Deep shear is supportive."],
            limitingFactors: [.weakLowLevelRotation],
            summary: "The setup is conditionally supportive."
        )
    }

    private func makeNormalizationResult(raw: TornadoRawParameters) -> TornadoIngredientNormalizationResult {
        TornadoIngredientNormalizationResult(raw: raw, diagnostics: [])
    }

    private func makeRaw(
        sbcapeJkg: Double? = nil,
        mlcapeJkg: Double? = nil,
        mucapeJkg: Double? = nil,
        mlcinJkg: Double? = nil,
        mllclM: Double? = nil,
        temperature2mK: Double? = nil,
        dewpoint2mK: Double? = nil,
        surfacePressurePa: Double? = nil,
        wind10m: DirectionSpeed? = nil,
        shear06kmKt: Double? = nil,
        srh01kmM2s2: Double? = nil,
        srh03kmM2s2: Double? = nil
    ) -> TornadoRawParameters {
        TornadoRawParameters(
            sbcapeJkg: sbcapeJkg,
            mlcapeJkg: mlcapeJkg,
            mucapeJkg: mucapeJkg,
            mlcinJkg: mlcinJkg,
            dcapeJkg: nil,
            mllclM: mllclM,
            tempDewPtDeltaF: nil,
            temperature2mK: temperature2mK,
            dewpoint2mK: dewpoint2mK,
            surfacePressurePa: surfacePressurePa,
            wind10m: wind10m,
            lclLfcSeparationM: nil,
            lapseRate03kmCkm: nil,
            lapseRate700500mbCkm: nil,
            shear06kmKt: shear06kmKt,
            shear03kmKt: nil,
            shear01kmKt: nil,
            effectiveShearKt: nil,
            srh01kmM2s2: srh01kmM2s2,
            srh03kmM2s2: srh03kmM2s2,
            effectiveSrhM2s2: nil,
            supercellComposite: nil,
            significantTornadoFixed: nil,
            significantTornadoEffective: nil,
            significantHail: nil,
            bunkersRightMotion: nil,
            bunkersLeftMotion: nil,
            stormRelativeWind46km: nil,
            meanWind850300mb: nil,
            diagnostics: []
        )
    }

    private func makeFreshness(now: Date) -> IngredientFreshness {
        IngredientFreshness(
            sourceValidTime: now,
            modelRunTime: now,
            forecastHour: 0,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(90 * 60),
            isStale: false,
            isDegraded: false
        )
    }

    private func makeSnapshot(
        h3Cell: Int64,
        source: StormSetupSourceMetadata,
        fetchedAt: Date,
        raw: TornadoRawParameters,
        surfaceHeightMslM: Double? = nil,
        assessment: TornadoIngredientAssessment,
        freshness: IngredientFreshness,
        anvilEvidence: AnvilIngredientEvidence? = nil
    ) -> TornadoIngredientSnapshot {
        TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
            source: source,
            raw: raw,
            surfaceHeightMslM: surfaceHeightMslM,
            assessment: assessment,
            freshness: freshness,
            anvilEvidence: anvilEvidence
        )
    }
}

private enum TestFailure: Error, Sendable {
    case unexpectedDownstreamCall(String)
}

private actor StubStormSetupSnapshotCache: StormSetupSnapshotCaching {
    var cachedSnapshot: TornadoIngredientSnapshot?
    private(set) var loadCount = 0
    private(set) var storeCount = 0

    init(cachedSnapshot: TornadoIngredientSnapshot?) {
        self.cachedSnapshot = cachedSnapshot
    }

    func loadSnapshot(for key: StormSetupSnapshotCacheKey) async -> StormSetupSnapshotCacheResult? {
        loadCount += 1
        guard let cachedSnapshot else {
            return nil
        }

        return StormSetupSnapshotCacheResult(
            snapshot: cachedSnapshot,
            cacheHit: true,
            fetchedAt: cachedSnapshot.freshness.fetchedAt,
            expiresAt: cachedSnapshot.freshness.expiresAt,
            sourceValidTime: cachedSnapshot.freshness.sourceValidTime,
            rulesVersion: key.rulesVersion
        )
    }

    func store(snapshot: TornadoIngredientSnapshot, for key: StormSetupSnapshotCacheKey) async throws -> StormSetupSnapshotCacheResult {
        storeCount += 1
        cachedSnapshot = snapshot
        return StormSetupSnapshotCacheResult(
            snapshot: snapshot,
            cacheHit: false,
            fetchedAt: snapshot.freshness.fetchedAt,
            expiresAt: snapshot.freshness.expiresAt,
            sourceValidTime: snapshot.freshness.sourceValidTime,
            rulesVersion: key.rulesVersion
        )
    }
}

private actor StubStormSetupSubsetLoader: StormSetupSubsetLoading {
    private let responseProvider: @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> GribSubsetCacheResult
    private(set) var requestCount = 0

    init(
        responseProvider: @escaping @Sendable (Int, HrrrRunResolution, StormSetupCentroid) async throws -> GribSubsetCacheResult
    ) {
        self.responseProvider = responseProvider
    }

    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        let callIndex = requestCount
        requestCount += 1
        return try await responseProvider(callIndex, resolution, centroid)
    }
}

private actor StubStormSetupFieldSampler: StormSetupFieldSampling {
    private let responseProvider: @Sendable (GribSubsetCacheResult, StormSetupCentroid) async throws -> [HrrrFieldSample]
    private(set) var requestCount = 0

    init(
        responseProvider: @escaping @Sendable (GribSubsetCacheResult, StormSetupCentroid) async throws -> [HrrrFieldSample]
    ) {
        self.responseProvider = responseProvider
    }

    func sample(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        requestCount += 1
        return try await responseProvider(subset, centroid)
    }

    func sample(
        localFileURL: URL,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        requestCount += 1
        let syntheticSource = StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: nil,
            product: nil,
            domain: nil,
            runTime: nil,
            forecastHour: nil,
            validTime: nil,
            fieldSetVersion: nil,
            primaryDownloadURL: localFileURL
        )
        let subset = GribSubsetCacheResult(
            source: syntheticSource,
            localFileURL: localFileURL,
            byteSize: 0,
            fetchedAt: .distantPast,
            expiresAt: .distantFuture,
            cacheHit: true
        )
        return try await responseProvider(subset, centroid)
    }
}

private struct StubStormSetupNormalizer: StormSetupIngredientNormalizing, @unchecked Sendable {
    let result: TornadoIngredientNormalizationResult

    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult {
        _ = samples
        return result
    }
}

    private struct StubStormSetupAssessor: StormSetupIngredientAssessing, @unchecked Sendable {
        let assessment: TornadoIngredientAssessment

    func assess(
        raw: TornadoRawParameters,
        freshness: IngredientFreshness,
        evidence: AnvilIngredientEvidence?
    ) -> TornadoIngredientAssessment {
        _ = raw
        _ = freshness
        _ = evidence
        return assessment
    }
}

private struct StubAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let response: AnvilAnalyzeProfileAnalysisResponse

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        return response
    }
}

private actor CountingAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding {
    private let response: AnvilAnalyzeProfileAnalysisResponse
    private(set) var requestCount = 0

    init(response: AnvilAnalyzeProfileAnalysisResponse) {
        self.response = response
    }

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        requestCount += 1
        return response
    }
}

private actor CapturingAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding {
    private let response: AnvilAnalyzeProfileAnalysisResponse
    private(set) var requestCount = 0

    init(response: AnvilAnalyzeProfileAnalysisResponse) {
        self.response = response
    }

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        requestCount += 1
        return response
    }
}

private struct ThrowingAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let error: any Error

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        throw error
    }
}

private func makeProviderUTCDate(
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

struct StormSetupRouteDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

func makeStormSetupRouteProvider(now: Date) -> DefaultStormSetupProvider {
    let dateProvider = StormSetupRouteDateProvider(nowDate: now)
    let snapshotCache = StubStormSetupSnapshotCache(cachedSnapshot: nil)
    let subsetLoader = StubStormSetupSubsetLoader { _, resolution, centroid in
        guard let candidate = resolution.primaryCandidate else {
            throw TestFailure.unexpectedDownstreamCall("provider resolution was missing a primary candidate")
        }

        let source = HrrrNomadsURLBuilder().makeSourceMetadata(for: candidate, around: centroid)
        return GribSubsetCacheResult(
            source: source,
            localFileURL: URL(fileURLWithPath: "/tmp/arcus-signal-storm-setup-\(UUID().uuidString).grib2"),
            byteSize: 512,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(12 * 60 * 60),
            cacheHit: false
        )
    }
    let fieldSampler = StubStormSetupFieldSampler { _, centroid in
        [
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: Wgrib2PointSample.parse(
                    from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                )
            ),
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: Wgrib2PointSample.parse(
                    from: "2:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
                )
            ),
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: Wgrib2PointSample.parse(
                    from: "3:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
                )
            ),
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: Wgrib2PointSample.parse(
                    from: "4:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6"
                )
            ),
            HrrrFieldSample(
                requestedLongitude: centroid.longitude,
                requestedLatitude: centroid.latitude,
                point: Wgrib2PointSample.parse(
                    from: "5:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
                )
            )
        ]
    }

    return DefaultStormSetupProvider(
        dateProvider: dateProvider,
        snapshotCache: snapshotCache,
        subsetLoader: subsetLoader,
        fieldSampler: fieldSampler,
        normalizer: StubStormSetupNormalizer(
            result: TornadoIngredientNormalizationResult(
                raw: makeStormSetupRouteRaw(),
                diagnostics: []
            )
        ),
        interpreter: StubStormSetupAssessor(
            assessment: makeStormSetupRouteAssessment()
        ),
        anvilProfileAnalysisProvider: StubStormSetupRouteAnvilProfileAnalysisProvider(
            response: makeStormSetupRouteAnalysisResponse()
        ),
        logger: Logger(label: "storm-setup-tests")
    )
}

    func makeStormSetupRouteAnalysisResponse(
        validTime: Date = makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
        warnings: [String] = []
    ) -> AnvilAnalyzeProfileAnalysisResponse {
        AnvilAnalyzeProfileAnalysisResponse(
            request: AnvilAnalyzeProfileRequest(
                runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 0,
                validTime: validTime,
                location: AnvilLocationDTO(
                    lat: 39.7825,
                    lon: -104.4661,
                    h3: "617700169958293503"
                ),
                profile: AnvilProfileDTO(
                    pressureMb: [1000, 925, 850],
                    heightMslM: [1560, 780, 1450],
                    temperatureC: [28.4, 22.8, 17.5],
                    dewpointC: [12.3, 10.1, 11.2],
                    uWindMs: [-2.1, -5.4, -6.25],
                    vWindMs: [4.6, 7.9, 8.75]
                )
            ),
            debug: AnvilAnalyzeProfilePreviewDebugDTO(
                sourceKind: .directObject,
                product: .wrfprsf,
                runTime: makeProviderUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 0,
                validTime: validTime,
                h3: "617700169958293503",
                centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
                selectedMessageCount: 5,
                selectedPressureLevels: [1000, 925, 850],
                surfacePressureMb: 940,
                surfaceSubsetCacheHit: false,
                rangeCount: 3,
                totalSelectedRangeBytes: 1024,
                pressureLevelsRequested: [1000, 925, 850],
                pressureLevelsRetained: [1000, 925, 850],
                missingLevels: [],
                warnings: warnings,
                subsetCacheHit: false,
                primaryDownloadURL: nil,
                idxURL: nil,
                idxAvailable: true,
                gribAvailable: true
            ),
            response: AnvilAnalyzeProfileResponse(
                effectiveLayer: AnvilEffectiveLayerDTO(
                    status: "found",
                    basePressureMb: 1000,
                    topPressureMb: 925,
                    baseMetersAgl: 0,
                    topMetersAgl: 690
                ),
                stormMotion: AnvilStormMotionDTO(
                    status: "computed",
                    bunkersRight: AnvilBunkersRightStormMotionDTO(
                        uKt: 36.80394762849837,
                        vKt: 13.53066796460426,
                        speedKt: 39.21236458834915,
                        directionTowardDeg: 69.81446460119884,
                        uMs: 18.933570033795217,
                        vMs: 6.960770950382875,
                        speedMs: 20.172565688288692
                    )
                ),
                mucape: 362.1018454649957,
                mlcape: 191.7304143918497,
                mlcin: -221.93726424748172,
                mllclMetersAgl: 1179.4130766012365,
                effectiveSrh: 29.42420403684148,
                effectiveBulkShearMs: 30.134722226263612,
                scp: 4.2,
                stpCin: 0.0,
                stpFixed: 3.4,
                ship: 2.3,
                srh01km: 80,
                srh03km: 140,
                sbcape: 1450,
                sbcin: nil,
                bulkShear06kmMs: nil,
                lapserate03km: nil,
                threeCapeJkg: nil,
                quality: AnvilQualityDTO(
                    profileLevelCount: 20,
                    warnings: []
                )
            )
        )
    }

private struct StubStormSetupRouteAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let response: AnvilAnalyzeProfileAnalysisResponse

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        return response
    }
}

func makeStormSetupRouteRaw() -> TornadoRawParameters {
    TornadoRawParameters(
        sbcapeJkg: 1450,
        mlcapeJkg: 1080,
        mucapeJkg: 1500,
        mlcinJkg: -35,
        dcapeJkg: nil,
        mllclM: 950,
        tempDewPtDeltaF: 17,
        temperature2mK: 295.15,
        dewpoint2mK: 289.15,
        surfacePressurePa: 94_000,
        wind10m: DirectionSpeed(directionDegrees: 69.8, speedKt: 39.2),
        lclLfcSeparationM: nil,
        lapseRate03kmCkm: nil,
        lapseRate700500mbCkm: nil,
        shear06kmKt: 42,
        shear03kmKt: nil,
        shear01kmKt: nil,
        effectiveShearKt: 38,
        srh01kmM2s2: 80,
        srh03kmM2s2: 160,
        effectiveSrhM2s2: nil,
        supercellComposite: nil,
        significantTornadoFixed: nil,
        significantTornadoEffective: nil,
        significantHail: nil,
        bunkersRightMotion: nil,
        bunkersLeftMotion: nil,
        stormRelativeWind46km: nil,
        meanWind850300mb: nil,
        diagnostics: []
    )
}

func makeStormSetupRouteAssessment() -> TornadoIngredientAssessment {
    TornadoIngredientAssessment(
        overall: .conditional,
        instability: .supportive,
        moisture: .supportive,
        cloudBase: .supportive,
        capInhibition: .conditional,
        deepShear: .supportive,
        lowLevelRotation: .conditional,
        stormMode: .unknown,
        compositeSignal: .conditional,
        confidence: .moderate,
        trend: .unknown,
        stormModeHint: .unknown,
        primaryDrivers: [
            "Instability is supportive.",
            "Deep shear is supportive.",
            "Cloud bases are favorable."
        ],
        limitingFactors: [.weakLowLevelRotation],
        summary: "The setup is conditionally supportive. Instability and deep shear are present, but low-level rotation is modest."
    )
}
