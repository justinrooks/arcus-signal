@testable import App
import Foundation
import Logging
import Testing

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
        #expect(loadCount == 1)
        #expect(storeCount == 0)
        #expect(subsetRequestCount == 0)
        #expect(fieldSampleRequestCount == 0)
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
        let assessment = makeAssessment()
        let provider = makeProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: StubStormSetupNormalizer(result: normalized),
            interpreter: StubStormSetupAssessor(assessment: assessment)
        )

        let snapshot = try await provider.currentSnapshot(for: fixedH3)
        let loadCount = await snapshotCache.loadCount
        let storeCount = await snapshotCache.storeCount
        let subsetRequestCount = await subsetLoader.requestCount
        let fieldSampleRequestCount = await fieldSampler.requestCount

        #expect(snapshot.source.runTime == candidate.runTime)
        #expect(snapshot.source.forecastHour == candidate.forecastHour)
        #expect(snapshot.raw.sbcapeJkg == 1450)
        #expect(snapshot.assessment.overall == assessment.overall)
        #expect(loadCount == 1)
        #expect(storeCount == 1)
        #expect(subsetRequestCount == 1)
        #expect(fieldSampleRequestCount == 1)
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

    private func makeProvider(
        dateProvider: any StormSetupDateProviding,
        snapshotCache: any StormSetupSnapshotCaching,
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling,
        normalizer: any StormSetupIngredientNormalizing,
        interpreter: any StormSetupIngredientAssessing
    ) -> DefaultStormSetupProvider {
        DefaultStormSetupProvider(
            dateProvider: dateProvider,
            snapshotCache: snapshotCache,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler,
            normalizer: normalizer,
            interpreter: interpreter,
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
            temperatureDewpointSpreadF: nil,
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
        assessment: TornadoIngredientAssessment,
        freshness: IngredientFreshness
    ) -> TornadoIngredientSnapshot {
        TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
            source: source,
            raw: raw,
            assessment: assessment,
            freshness: freshness
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

    func assess(raw: TornadoRawParameters, freshness: IngredientFreshness) -> TornadoIngredientAssessment {
        _ = raw
        _ = freshness
        return assessment
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
        logger: Logger(label: "storm-setup-tests")
    )
}

func makeStormSetupRouteRaw() -> TornadoRawParameters {
    TornadoRawParameters(
        sbcapeJkg: 1450,
        mlcapeJkg: 1080,
        mucapeJkg: 1500,
        mlcinJkg: -35,
        dcapeJkg: nil,
        mllclM: 950,
        temperatureDewpointSpreadF: 17,
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
