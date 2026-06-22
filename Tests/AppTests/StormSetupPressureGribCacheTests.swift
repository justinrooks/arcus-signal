@testable import App
import Foundation
import Testing

@Suite("Storm setup pressure GRIB cache", .serialized)
struct StormSetupPressureGribCacheTests {
    @Test("pressure raw cache keys separate surface subset keys")
    func cacheKeysSeparateSurfaceSubsetKeys() throws {
        let rootURL = pressureTestRootURL()
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let surfaceSource = HrrrNomadsURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(
                runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9
            ),
            around: centroid
        )
        let pressureSource = HrrrPressureDirectObjectURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV1
            )
        )

        let surfaceKey = try StormSetupCacheKey(sourceMetadata: surfaceSource)
        let pressureKey = try StormSetupPressureGribCacheKey(sourceMetadata: pressureSource)

        #expect(surfaceKey.cacheIdentifier != pressureKey.cacheIdentifier)
        #expect(surfaceKey.subsetFileURL(rootURL: rootURL).path != pressureKey.rawFileURL(rootURL: rootURL).path)
    }

    @Test("pressure raw cache keys are stable for equivalent inputs")
    func cacheKeyIsStableForEquivalentInputs() throws {
        let rootURL = pressureTestRootURL()
        let source = HrrrPressureDirectObjectURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
                forecastHour: 0,
                fieldSetVersion: .tornadoPressureV1
            )
        )

        let keyA = try StormSetupPressureGribCacheKey(sourceMetadata: source)
        let keyB = try StormSetupPressureGribCacheKey(sourceMetadata: source)

        #expect(keyA == keyB)
        #expect(keyA.cacheIdentifier == keyB.cacheIdentifier)
        #expect(keyA.rawFileURL(rootURL: rootURL).path == keyB.rawFileURL(rootURL: rootURL).path)
    }

    @Test("cache miss downloads pressure raw files then cache hit skips network")
    func cacheMissWritesThenHitSkipsDownloader() async throws {
        let rootURL = pressureTestRootURL()
        let source = makeSourceMetadata(
            runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0
        )
        let responseData = Data("pressure-grib".utf8)
        let client = PressureStubHTTPClient(
            plannedResponses: [
                source.primaryDownloadURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let cache = StormSetupPressureGribCache(
            httpClient: client,
            rootURL: rootURL,
            dateProvider: FixedPressureStormSetupDateProvider(nowDate: pressureMakeUTCDate(year: 2026, month: 6, day: 20, hour: 6)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        let first = try await cache.loadOrFetch(sourceMetadata: source)
        let second = try await cache.loadOrFetch(sourceMetadata: source)

        #expect(first.cacheHit == false)
        #expect(second.cacheHit == true)
        #expect(first.localFileURL == second.localFileURL)
        #expect(first.byteSize == Int64(responseData.count))
        #expect(first.checksumSHA256 == second.checksumSHA256)
        #expect(client.requestCount == 1)
        #expect(FileManager.default.fileExists(atPath: first.localFileURL.path))
        #expect(try Data(contentsOf: first.localFileURL) == responseData)
    }

    @Test("corrupt cached pressure files are invalidated and redownloaded")
    func corruptCacheEntryTriggersRedownload() async throws {
        let rootURL = pressureTestRootURL()
        let source = makeSourceMetadata(
            runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0
        )
        let initialData = Data("first-pass".utf8)
        let client = PressureStubHTTPClient(
            plannedResponses: [
                source.primaryDownloadURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: initialData)
                )
            ]
        )
        let cache = StormSetupPressureGribCache(
            httpClient: client,
            rootURL: rootURL,
            dateProvider: FixedPressureStormSetupDateProvider(nowDate: pressureMakeUTCDate(year: 2026, month: 6, day: 20, hour: 6)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        let first = try await cache.loadOrFetch(sourceMetadata: source)
        try Data("corrupt".utf8).write(to: first.localFileURL, options: [.atomic])

        let second = try await cache.loadOrFetch(sourceMetadata: source)

        #expect(second.cacheHit == false)
        #expect(client.requestCount == 2)
        #expect(try Data(contentsOf: second.localFileURL) == initialData)
    }

    @Test("metadata mismatch invalidates pressure cache entries and refetches")
    func metadataMismatchTriggersRedownload() async throws {
        let rootURL = pressureTestRootURL()
        let source = makeSourceMetadata(
            runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0
        )
        let responseData = Data("pressure-grib".utf8)
        let client = PressureStubHTTPClient(
            plannedResponses: [
                source.primaryDownloadURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let cache = StormSetupPressureGribCache(
            httpClient: client,
            rootURL: rootURL,
            dateProvider: FixedPressureStormSetupDateProvider(nowDate: pressureMakeUTCDate(year: 2026, month: 6, day: 20, hour: 6)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        let first = try await cache.loadOrFetch(sourceMetadata: source)
        let metadataURL = try StormSetupPressureGribCacheKey(sourceMetadata: source).metadataFileURL(rootURL: rootURL)
        let metadataData = try Data(contentsOf: metadataURL)
        let jsonObject = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        var mutated = jsonObject ?? [:]
        var mutatedKey = mutated["key"] as? [String: Any] ?? [:]
        mutatedKey["sourceKind"] = "nomadsFilteredSubset"
        mutated["key"] = mutatedKey
        let mutatedData = try JSONSerialization.data(withJSONObject: mutated)
        try mutatedData.write(to: metadataURL, options: [.atomic])

        let second = try await cache.loadOrFetch(sourceMetadata: source)

        #expect(first.cacheHit == false)
        #expect(second.cacheHit == false)
        #expect(client.requestCount == 2)
        #expect(try Data(contentsOf: second.localFileURL) == responseData)
    }

    @Test("oversized pressure responses fail clearly")
    func cacheRejectsOversizedResponses() async throws {
        let source = makeSourceMetadata(
            runTime: pressureMakeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0
        )
        let cacheKey = try StormSetupPressureGribCacheKey(sourceMetadata: source)
        let responseData = Data(repeating: 0x41, count: 5)
        let client = PressureStubHTTPClient(
            plannedResponses: [
                source.primaryDownloadURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let rootURL = pressureTestRootURL()
        let cache = StormSetupPressureGribCache(
            httpClient: client,
            rootURL: rootURL,
            dateProvider: FixedPressureStormSetupDateProvider(nowDate: pressureMakeUTCDate(year: 2026, month: 6, day: 20, hour: 6)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 4
        )

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected an oversized response error.")
        } catch let error as StormSetupPressureGribCacheError {
            guard case .responseTooLarge(let returnedSource, let byteCount, let maximumByteCount) = error else {
                Issue.record("Expected responseTooLarge, got \(error).")
                return
            }

            #expect(returnedSource.model == source.model)
            #expect(returnedSource.product == source.product)
            #expect(returnedSource.domain == source.domain)
            #expect(returnedSource.runTime == source.runTime)
            #expect(returnedSource.forecastHour == source.forecastHour)
            #expect(returnedSource.validTime == source.validTime)
            #expect(returnedSource.fieldSetVersion == source.fieldSetVersion)
            #expect(byteCount == responseData.count)
            #expect(maximumByteCount == 4)
            #expect(client.requestCount == 1)
            #expect(!FileManager.default.fileExists(atPath: cacheKey.rawFileURL(rootURL: rootURL).path))
        }
    }

    private func makeSourceMetadata(
        runTime: Date,
        forecastHour: Int
    ) -> StormSetupSourceMetadata {
        let candidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: forecastHour,
            fieldSetVersion: .tornadoPressureV1
        )
        return HrrrPressureDirectObjectURLBuilder().makeSourceMetadata(for: candidate)
    }

    private func pressureTestRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-grib-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class PressureStubHTTPClient: HTTPClient, @unchecked Sendable {
    enum PlannedResponse: Sendable {
        case success(HTTPResponse)
    }

    private var plannedResponses: [String: PlannedResponse]
    private var requests: [URL] = []

    init(plannedResponses: [String: PlannedResponse] = [:]) {
        self.plannedResponses = plannedResponses
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        requests.append(url)

        guard let plannedResponse = plannedResponses[url.absoluteString] else {
            throw URLError(.badServerResponse)
        }

        switch plannedResponse {
        case .success(let response):
            return response
        }
    }

    func head(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func clearCache() {}

    var requestCount: Int {
        requests.count
    }
}

private struct FixedPressureStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

private func pressureMakeUTCDate(
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
        preconditionFailure("Unable to create UTC date for pressure test.")
    }

    return date
}
