@testable import App
import Foundation
import Testing
import ArcusCore

@Suite("Storm setup sampled snapshot cache", .serialized)
struct StormSetupSnapshotCacheTests {
    @Test("equivalent key inputs map to the same cache path")
    func equivalentInputsMapToSamePath() throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )

        let keyA = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let keyB = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: source,
            rulesVersion: .current
        )

        #expect(keyA == keyB)
        #expect(keyA.cacheIdentifier == keyB.cacheIdentifier)
        #expect(keyA.snapshotFileURL(rootURL: rootURL).path == keyB.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("snapshot cache keys separate surface and pressure-level sources")
    func snapshotCacheKeysSeparateSurfaceAndPressureSources() throws {
        let rootURL = testRootURL()
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let builder = HrrrNomadsURLBuilder()
        let surfaceSource = builder.makeSourceMetadata(
            for: HrrrRunCandidate(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9
            ),
            around: centroid
        )
        let pressureSource = builder.makeSourceMetadata(
            for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV1
            ),
            around: centroid
        )

        let surfaceKey = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: surfaceSource,
            rulesVersion: .current
        )
        let pressureKey = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: pressureSource,
            rulesVersion: .current
        )

        #expect(surfaceKey != pressureKey)
        #expect(surfaceKey.cacheIdentifier != pressureKey.cacheIdentifier)
        #expect(surfaceKey.snapshotFileURL(rootURL: rootURL).path != pressureKey.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("different H3 cells map to different cache paths")
    func differentH3CellsMapToDifferentPaths() throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )

        let keyA = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let keyB = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_648,
            sourceMetadata: source,
            rulesVersion: .current
        )

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.snapshotFileURL(rootURL: rootURL).path != keyB.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("different run times map to different cache paths")
    func differentRunTimesMapToDifferentPaths() throws {
        let rootURL = testRootURL()
        let sourceA = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let sourceB = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14),
            forecastHour: 9
        )

        let keyA = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: sourceA,
            rulesVersion: .current
        )
        let keyB = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: sourceB,
            rulesVersion: .current
        )

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.snapshotFileURL(rootURL: rootURL).path != keyB.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("different forecast hours map to different cache paths")
    func differentForecastHoursMapToDifferentPaths() throws {
        let rootURL = testRootURL()
        let sourceA = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let sourceB = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 10
        )

        let keyA = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: sourceA,
            rulesVersion: .current
        )
        let keyB = try StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            sourceMetadata: sourceB,
            rulesVersion: .current
        )

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.snapshotFileURL(rootURL: rootURL).path != keyB.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("different valid times map to different cache paths")
    func differentValidTimesMapToDifferentPaths() throws {
        let rootURL = testRootURL()
        let keyA = StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoV1,
            rulesVersion: .current
        )
        let keyB = StormSetupSnapshotCacheKey(
            h3Cell: 882_681_611_511_963_647,
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
            fieldSetVersion: .tornadoV1,
            rulesVersion: .current
        )

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.snapshotFileURL(rootURL: rootURL).path != keyB.snapshotFileURL(rootURL: rootURL).path)
    }

    @Test("different rules versions miss the cache")
    func differentRulesVersionsMissTheCache() async throws {
        let rootURL = testRootURL()
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(
            rootURL: rootURL,
            now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            blockingWorkExecutor: blockingWork.executor
        )
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let keyV1 = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let keyV2 = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .tornadoIngredientV2
        )
        let snapshot = makeSnapshot(h3Cell: h3Cell, source: source, fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))

        _ = try await cache.store(snapshot: snapshot, for: keyV1)
        let loaded = await cache.loadSnapshot(for: keyV2)

        #expect(loaded == nil)
    }

    @Test("snapshot cache key construction rejects missing source metadata")
    func snapshotCacheKeyRejectsMissingSourceMetadata() {
        let source = StormSetupSourceMetadata(
            model: .hrrr,
            product: nil,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoV1,
            bbox: StormSetupHrrrBoundingBox(
                around: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
            ),
            nomadsURL: URL(string: "https://example.com/subset.grib2")
        )

        #expect(throws: StormSetupSnapshotCacheKeyError.self) {
            _ = try StormSetupSnapshotCacheKey(
                h3Cell: 882_681_611_511_963_647,
                sourceMetadata: source,
                rulesVersion: .current
            )
        }
    }

    @Test("fresh cache entry reads successfully and round-trips")
    func freshCacheEntryReadsSuccessfully() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let countingExecutor = CountingPressureArtifactBlockingWorkExecutor(wrapping: blockingWork.executor)
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: countingExecutor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let snapshot = makeSnapshot(
            h3Cell: h3Cell,
            source: source,
            fetchedAt: now,
            expiresAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
        )

        let stored = try await cache.store(snapshot: snapshot, for: key)
        let storeExecutionCount = await countingExecutor.executionCount()
        let loaded = await cache.loadSnapshot(for: key)
        let loadExecutionCount = await countingExecutor.executionCount()

        #expect(stored.cacheHit == false)
        #expect(stored.fetchedAt == now)
        #expect(stored.expiresAt == makeUTCDate(year: 2026, month: 6, day: 3, hour: 23))
        #expect(stored.rulesVersion == .current)
        #expect(loaded?.cacheHit == true)
        #expect(loaded?.fetchedAt == now)
        #expect(loaded?.expiresAt == makeUTCDate(year: 2026, month: 6, day: 3, hour: 23))
        #expect(loaded?.rulesVersion == .current)
        #expect(loaded?.snapshot.h3Cell == snapshot.h3Cell)
        #expect(loaded?.snapshot.source.model == snapshot.source.model)
        #expect(loaded?.snapshot.source.product == snapshot.source.product)
        #expect(loaded?.snapshot.source.domain == snapshot.source.domain)
        #expect(loaded?.snapshot.source.runTime == snapshot.source.runTime)
        #expect(loaded?.snapshot.source.forecastHour == snapshot.source.forecastHour)
        #expect(loaded?.snapshot.source.validTime == snapshot.source.validTime)
        #expect(loaded?.snapshot.source.fieldSetVersion == snapshot.source.fieldSetVersion)
        #expect(loaded?.snapshot.freshness.expiresAt == snapshot.freshness.expiresAt)
        #expect(loaded?.snapshot.freshness.fetchedAt == snapshot.freshness.fetchedAt)
        #expect(loaded?.snapshot.freshness.sourceValidTime == snapshot.freshness.sourceValidTime)
        #expect(loaded?.snapshot.raw.sbcapeJkg == snapshot.raw.sbcapeJkg)
        #expect(loaded?.snapshot.assessment.overall == snapshot.assessment.overall)
        #expect(storeExecutionCount > 0)
        #expect(loadExecutionCount > storeExecutionCount)
    }

    @Test("stored snapshots round-trip as surface-only records")
    func storedSnapshotsRoundTripAsSurfaceOnlyRecords() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: blockingWork.executor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let snapshot = makeSnapshot(
            h3Cell: h3Cell,
            source: source,
            fetchedAt: now,
            expiresAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
            anvilEvidence: AnvilIngredientEvidence.unavailable(reason: "Cached Anvil evidence should not be authoritative.")
        )

        _ = try await cache.store(snapshot: snapshot, for: key)
        let loaded = await cache.loadSnapshot(for: key)

        #expect(loaded?.snapshot.anvilEvidence == nil)
    }

    @Test("cached snapshots with stripped Anvil evidence recompute the baseline assessment")
    func cachedSnapshotsWithStrippedAnvilEvidenceRecomputeBaselineAssessment() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: blockingWork.executor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let freshness = IngredientFreshness(
            sourceValidTime: source.validTime,
            modelRunTime: source.runTime,
            forecastHour: source.forecastHour,
            fetchedAt: now,
            expiresAt: now.addingTimeInterval(90 * 60),
            isStale: false,
            isDegraded: false
        )
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
        let staleEvidence = AnvilIngredientEvidence.unavailable(reason: "Legacy cache record carried evidence that should be stripped.")
        let cachedSnapshot = TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
            source: source,
            raw: raw,
            assessment: TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness, evidence: staleEvidence),
            freshness: freshness,
            anvilEvidence: staleEvidence
        )
        let expectedAssessment = TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness)

        _ = try await cache.store(snapshot: cachedSnapshot, for: key)
        let loaded = await cache.loadSnapshot(for: key)

        #expect(loaded?.snapshot.anvilEvidence == nil)
        #expect(loaded?.snapshot.assessment.overall == expectedAssessment.overall)
        #expect(loaded?.snapshot.assessment.confidence == expectedAssessment.confidence)
        #expect(loaded?.snapshot.assessment.summary == expectedAssessment.summary)
        #expect(loaded?.snapshot.assessment.primaryDrivers == expectedAssessment.primaryDrivers)
        #expect(loaded?.snapshot.assessment.limitingFactors == expectedAssessment.limitingFactors)
    }

    @Test("expired cache entries are ignored")
    func expiredCacheEntriesAreIgnored() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let countingExecutor = CountingPressureArtifactBlockingWorkExecutor(wrapping: blockingWork.executor)
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: countingExecutor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let snapshot = makeSnapshot(
            h3Cell: h3Cell,
            source: source,
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            expiresAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
        )

        _ = try await cache.store(snapshot: snapshot, for: key)
        let executionCountBeforeInvalidation = await countingExecutor.executionCount()
        let loaded = await cache.loadSnapshot(for: key)
        let executionCountAfterInvalidation = await countingExecutor.executionCount()

        #expect(loaded == nil)
        #expect(!fileExists(at: key.snapshotFileURL(rootURL: rootURL)))
        #expect(executionCountAfterInvalidation > executionCountBeforeInvalidation)
    }

    @Test("corrupt cache JSON is ignored safely")
    func corruptCacheJSONIsIgnoredSafely() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: blockingWork.executor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let fileURL = key.snapshotFileURL(rootURL: rootURL)
        try createParentDirectories(for: fileURL)
        try Data("{".utf8).write(to: fileURL, options: [.atomic])

        let loaded = await cache.loadSnapshot(for: key)

        #expect(loaded == nil)
        #expect(!fileExists(at: fileURL))
    }

    @Test("truncated cache files are ignored after a failed or partial write")
    func truncatedCacheFilesAreIgnored() async throws {
        let rootURL = testRootURL()
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(rootURL: rootURL, now: now, blockingWorkExecutor: blockingWork.executor)
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let h3Cell: Int64 = 882_681_611_511_963_647
        let key = try StormSetupSnapshotCacheKey(
            h3Cell: h3Cell,
            sourceMetadata: source,
            rulesVersion: .current
        )
        let fileURL = key.snapshotFileURL(rootURL: rootURL)
        try createParentDirectories(for: fileURL)
        try Data("{\"key\":".utf8).write(to: fileURL, options: [.atomic])

        let loaded = await cache.loadSnapshot(for: key)

        #expect(loaded == nil)
        #expect(!fileExists(at: fileURL))
    }

    private func makeCache(
        rootURL: URL,
        now: Date,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    ) -> StormSetupSnapshotCache {
        StormSetupSnapshotCache(
            blockingWorkExecutor: blockingWorkExecutor,
            rootURL: rootURL,
            dateProvider: FixedStormSetupDateProvider(nowDate: now)
        )
    }

    private func makeSourceMetadata(
        runTime: Date,
        forecastHour: Int
    ) -> StormSetupSourceMetadata {
        let candidate = HrrrRunCandidate(runTime: runTime, forecastHour: forecastHour)
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        return HrrrNomadsURLBuilder().makeSourceMetadata(for: candidate, around: centroid)
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
            tempDewPtDeltaF: nil,
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
            meanWind850300mb: nil
        )
    }

    private func makeSnapshot(
        h3Cell: Int64,
        source: StormSetupSourceMetadata,
        fetchedAt: Date,
        expiresAt: Date? = nil,
        anvilEvidence: AnvilIngredientEvidence? = nil
    ) -> TornadoIngredientSnapshot {
        let freshness = IngredientFreshness(
            sourceValidTime: source.validTime,
            modelRunTime: source.runTime,
            forecastHour: source.forecastHour,
            fetchedAt: fetchedAt,
            expiresAt: expiresAt ?? fetchedAt.addingTimeInterval(90 * 60),
            isStale: (expiresAt ?? fetchedAt.addingTimeInterval(90 * 60)) <= fetchedAt,
            isDegraded: false
        )

        return TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
            source: source,
            raw: .empty,
            assessment: TornadoIngredientInterpreter().assess(raw: .empty, freshness: freshness),
            freshness: freshness,
            anvilEvidence: anvilEvidence
        )
    }

    private func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func createParentDirectories(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    private func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("storm-setup-snapshot-cache-tests-\(UUID().uuidString)", isDirectory: true)
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
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}
