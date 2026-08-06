@testable import App
import Foundation
import Testing
import ArcusCore

@Suite("HRRR pressure subset GRIB cache", .serialized)
struct HrrrPressureSubsetGribCacheTests {
    @Test("cache key is deterministic for equivalent source metadata and ranges")
    func cacheKeyIsDeterministicForEquivalentSourceMetadataAndRanges() throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
            idxURL: URL(string: "https://example.com/a.idx")!
        )
        let plan = makePlan()
        let keyA = try HrrrPressureSubsetGribCacheKey(sourceMetadata: source, byteRangePlan: plan)
        let keyB = try HrrrPressureSubsetGribCacheKey(sourceMetadata: source, byteRangePlan: plan)

        #expect(keyA == keyB)
        #expect(keyA.cacheIdentifier == keyB.cacheIdentifier)
        #expect(keyA.subsetFileURL(rootURL: rootURL).path == keyB.subsetFileURL(rootURL: rootURL).path)
    }

    @Test("cache keys separate surface and pressure subset caches")
    func cacheKeysSeparateSurfaceAndSubsetCaches() throws {
        let rootURL = testRootURL()
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let surfaceSource = HrrrNomadsURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9
            ),
            around: centroid
        )
        let subsetSource = makeSourceMetadata(
            primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
            idxURL: URL(string: "https://example.com/a.idx")!
        )
        let plan = makePlan()

        let surfaceKey = try StormSetupCacheKey(sourceMetadata: surfaceSource)
        let subsetKey = try HrrrPressureSubsetGribCacheKey(sourceMetadata: subsetSource, byteRangePlan: plan)

        #expect(surfaceKey.subsetFileURL(rootURL: rootURL).path != subsetKey.subsetFileURL(rootURL: rootURL).path)
    }

    @Test("cache key changes when source URL or selected ranges change")
    func cacheKeyChangesWhenSourceURLOrRangesChange() throws {
        let sourceA = makeSourceMetadata(
            primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
            idxURL: URL(string: "https://example.com/a.idx")!
        )
        let sourceB = makeSourceMetadata(
            primaryDownloadURL: URL(string: "https://example.com/b.grib2")!,
            idxURL: URL(string: "https://example.com/b.idx")!
        )
        let planA = makePlan()
        let planB = makePlan(reversedInventory: true)

        let keyA = try HrrrPressureSubsetGribCacheKey(sourceMetadata: sourceA, byteRangePlan: planA)
        let keyB = try HrrrPressureSubsetGribCacheKey(sourceMetadata: sourceB, byteRangePlan: planA)
        let keyC = try HrrrPressureSubsetGribCacheKey(sourceMetadata: sourceA, byteRangePlan: planB)

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.cacheIdentifier != keyC.cacheIdentifier)
    }

    @Test("cache miss downloads then cache hit skips the downloader")
    func cacheMissWritesThenHitSkipsDownloader() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let rootURL = testRootURL()
            let source = makeSourceMetadata(
                primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
                idxURL: URL(string: "https://example.com/a.idx")!
            )
            let plan = makePlan()
            let client = PressureSubsetStubHTTPClient(
                plannedResponses: makePlannedResponses(for: source, plan: plan, payloads: [
                    Data("hgt-".utf8),
                    Data("tmp-".utf8),
                    Data("dpt-".utf8),
                    Data("ugrd".utf8),
                    Data("vgrd".utf8)
                ])
            )
            let cache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: FixedSubsetStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )

            let first = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)
            let second = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)

            #expect(first.cacheHit == false)
            #expect(second.cacheHit == true)
            #expect(first.localFileURL == second.localFileURL)
            #expect(first.byteSize == 20)
            #expect(client.requestCount == 5)
            #expect(try Data(contentsOf: first.localFileURL) == Data("hgt-tmp-dpt-ugrdvgrd".utf8))
        }
    }

    @Test("expired cached subset files are invalidated and redownloaded")
    func expiredCacheEntryTriggersRedownload() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let rootURL = testRootURL()
            let source = makeSourceMetadata(
                primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
                idxURL: URL(string: "https://example.com/a.idx")!
            )
            let plan = makePlan()
            let client = PressureSubsetStubHTTPClient(
                plannedResponses: makePlannedResponses(for: source, plan: plan, payloads: [
                    Data("hgt-".utf8),
                    Data("tmp-".utf8),
                    Data("dpt-".utf8),
                    Data("ugrd".utf8),
                    Data("vgrd".utf8)
                ])
            )
            let cache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: FixedSubsetStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
                retentionDuration: 30 * 60,
                maximumByteCount: 1024
            )

            let first = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)

            let expiredCache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: FixedSubsetStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)),
                retentionDuration: 30 * 60,
                maximumByteCount: 1024
            )

            let second = try await expiredCache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)

            #expect(first.cacheHit == false)
            #expect(second.cacheHit == false)
            #expect(first.localFileURL == second.localFileURL)
            #expect(client.requestCount == 10)
            #expect(try Data(contentsOf: second.localFileURL) == Data("hgt-tmp-dpt-ugrdvgrd".utf8))
        }
    }

    @Test("corrupt cached subset files are invalidated and redownloaded")
    func corruptCacheEntryTriggersRedownload() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let rootURL = testRootURL()
            let source = makeSourceMetadata(
                primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
                idxURL: URL(string: "https://example.com/a.idx")!
            )
            let plan = makePlan()
            let client = PressureSubsetStubHTTPClient(
                plannedResponses: makePlannedResponses(for: source, plan: plan, payloads: [
                    Data("hgt-".utf8),
                    Data("tmp-".utf8),
                    Data("dpt-".utf8),
                    Data("ugrd".utf8),
                    Data("vgrd".utf8)
                ])
            )
            let cache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: FixedSubsetStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )

            let first = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)
            try Data("corrupt".utf8).write(to: first.localFileURL, options: [.atomic])

            let second = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)

            #expect(second.cacheHit == false)
            #expect(client.requestCount == 10)
            #expect(try Data(contentsOf: second.localFileURL) == Data("hgt-tmp-dpt-ugrdvgrd".utf8))
        }
    }

    @Test("invalidate removes both cached subset and metadata")
    func invalidateRemovesBothCachedSubsetAndMetadata() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let rootURL = testRootURL()
            let source = makeSourceMetadata(
                primaryDownloadURL: URL(string: "https://example.com/a.grib2")!,
                idxURL: URL(string: "https://example.com/a.idx")!
            )
            let plan = makePlan()
            let client = PressureSubsetStubHTTPClient(
                plannedResponses: makePlannedResponses(for: source, plan: plan, payloads: [
                    Data("hgt-".utf8),
                    Data("tmp-".utf8),
                    Data("dpt-".utf8),
                    Data("ugrd".utf8),
                    Data("vgrd".utf8)
                ])
            )
            let cache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: FixedSubsetStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )

            let loaded = try await cache.loadOrFetch(sourceMetadata: source, byteRangePlan: plan)
            let key = try HrrrPressureSubsetGribCacheKey(sourceMetadata: source, byteRangePlan: plan)

            try await cache.invalidate(sourceMetadata: source, byteRangePlan: plan)

            #expect(FileManager.default.fileExists(atPath: key.subsetFileURL(rootURL: rootURL).path) == false)
            #expect(FileManager.default.fileExists(atPath: key.metadataFileURL(rootURL: rootURL).path) == false)
            #expect(FileManager.default.fileExists(atPath: loaded.localFileURL.path) == false)
        }
    }

    private func makePlan(reversedInventory: Bool = false) -> HrrrGribByteRangePlan {
        let inventoryText = reversedInventory
            ? """
              1:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
              2:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
              3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
              4:4:d=2026060313:TMP:1000 mb:9 hour fcst:
              5:0:d=2026060313:HGT:1000 mb:9 hour fcst:
              6:20:d=2026060313:HGT:925 mb:9 hour fcst:
              """
            : """
              1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
              2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
              3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
              4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
              5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
              6:20:d=2026060313:HGT:925 mb:9 hour fcst:
              """
        let inventory = HrrrPressureIdxInventory.parse(inventoryText)
        let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
        return HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
    }

    private func makeSourceMetadata(
        primaryDownloadURL: URL,
        idxURL: URL
    ) -> StormSetupSourceMetadata {
        StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: .hrrr,
            product: .wrfprsf,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoPressureV1,
            primaryDownloadURL: primaryDownloadURL,
            idxURL: idxURL
        )
    }

    private func makePlannedResponses(
        for source: StormSetupSourceMetadata,
        plan: HrrrGribByteRangePlan,
        payloads: [Data]
    ) -> [String: HTTPResponse] {
        Dictionary(uniqueKeysWithValues: zip(plan.ranges, payloads).map { range, payload in
            let contentRange = range.closedRange.map { "bytes \($0.lowerBound)-\($0.upperBound)/20" } ?? "bytes \(range.startOffset)-\(range.startOffset + Int64(payload.count) - 1)/20"
            let response = HTTPResponse(
                status: 206,
                headers: {
                    var headers = ["Content-Type": "application/octet-stream"]
                    headers["Content-Range"] = contentRange
                    return headers
                }(),
                data: payload
            )
            return (source.primaryDownloadURL!.absoluteString + "|" + range.httpRangeHeaderValue, response)
        })
    }

    private func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hrrr-pressure-subset-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class PressureSubsetStubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let url: URL
        let headers: [String: String]
    }

    private let plannedResponses: [String: HTTPResponse]
    private(set) var requests: [Request] = []

    init(plannedResponses: [String: HTTPResponse] = [:]) {
        self.plannedResponses = plannedResponses
    }

    func get(_ url: URL, headers: [String : String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        _ = timeoutSeconds
        requests.append(Request(url: url, headers: headers))
        let key = url.absoluteString + "|" + (headers["Range"] ?? "")
        if let response = plannedResponses[key] {
            return response
        }

        if let response = plannedResponses[url.absoluteString] {
            return response
        }

        if let response = plannedResponses[headers["Range"] ?? ""] {
            return response
        }

        throw URLError(.badServerResponse)
    }

    func head(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func post(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await post(url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    }

    func clearCache() {}

    var requestCount: Int { requests.count }
}

private struct FixedSubsetStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
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
        preconditionFailure("Unable to create UTC date for pressure subset tests.")
    }

    return date
}
