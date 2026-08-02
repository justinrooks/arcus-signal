@testable import App
import Dispatch
import Foundation
import Testing
import ArcusCore

@Suite("Storm setup GRIB subset cache", .serialized)
struct StormSetupGribSubsetCacheTests {
    @Test("cache key is deterministic for equivalent source metadata")
    func cacheKeyIsDeterministic() throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let keyA = try StormSetupCacheKey(sourceMetadata: source)
        let keyB = try StormSetupCacheKey(sourceMetadata: source)

        #expect(keyA == keyB)
        #expect(keyA.cacheIdentifier == keyB.cacheIdentifier)
        #expect(keyA.subsetFileURL(rootURL: rootURL).path == keyB.subsetFileURL(rootURL: rootURL).path)
    }

    @Test("cache keys separate surface and pressure-level sources")
    func cacheKeysSeparateSurfaceAndPressureSources() throws {
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

        let surfaceKey = try StormSetupCacheKey(sourceMetadata: surfaceSource)
        let pressureKey = try StormSetupCacheKey(sourceMetadata: pressureSource)

        #expect(surfaceKey != pressureKey)
        #expect(surfaceKey.cacheIdentifier != pressureKey.cacheIdentifier)
        #expect(surfaceKey.subsetFileURL(rootURL: rootURL).path != pressureKey.subsetFileURL(rootURL: rootURL).path)
    }

    @Test("cache key changes when run time or forecast hour changes")
    func cacheKeyChangesForDifferentRunOrForecastHour() throws {
        let sourceA = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let sourceB = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14),
            forecastHour: 9
        )
        let sourceC = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 8
        )

        let keyA = try StormSetupCacheKey(sourceMetadata: sourceA)
        let keyB = try StormSetupCacheKey(sourceMetadata: sourceB)
        let keyC = try StormSetupCacheKey(sourceMetadata: sourceC)

        #expect(keyA.cacheIdentifier != keyB.cacheIdentifier)
        #expect(keyA.cacheIdentifier != keyC.cacheIdentifier)
    }

    @Test("cache key construction rejects missing source metadata")
    func cacheKeyRejectsMissingSourceMetadata() {
        let source = StormSetupSourceMetadata(
            model: nil,
            product: .wrfsfc,
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

        #expect(throws: StormSetupCacheKeyError.self) {
            _ = try StormSetupCacheKey(sourceMetadata: source)
        }
    }

    @Test("cache miss downloads, writes file, then cache hit skips the downloader")
    func cacheMissWritesThenHitSkipsDownloader() async throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let responseData = Data("grib-subset".utf8)
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let countingExecutor = CountingPressureArtifactBlockingWorkExecutor(wrapping: blockingWork.executor)
        let cache = GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: countingExecutor,
            rootURL: rootURL,
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        let first = try await cache.loadOrFetch(sourceMetadata: source)
        let missExecutionCount = await countingExecutor.executionCount()
        let second = try await cache.loadOrFetch(sourceMetadata: source)
        let hitExecutionCount = await countingExecutor.executionCount()

        #expect(first.cacheHit == false)
        #expect(second.cacheHit == true)
        #expect(first.localFileURL == second.localFileURL)
        #expect(first.byteSize == Int64(responseData.count))
        #expect(second.byteSize == Int64(responseData.count))
        #expect(client.requestCount == 1)
        #expect(missExecutionCount > 0)
        #expect(hitExecutionCount > missExecutionCount)
        #expect(FileManager.default.fileExists(atPath: first.localFileURL.path))

        let cachedData = try Data(contentsOf: first.localFileURL)
        #expect(cachedData == responseData)
    }

    @Test("cache rejects empty responses")
    func cacheRejectsEmptyResponses() async throws {
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: Data())
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(client: client, blockingWorkExecutor: blockingWork.executor)

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected an empty body error.")
        } catch let error as GribSubsetCacheError {
            guard case .emptyResponseBody(let returnedSource) = error else {
                Issue.record("Expected emptyResponseBody, got \(error).")
                return
            }

            #expect(returnedSource.model == source.model)
            #expect(returnedSource.product == source.product)
            #expect(returnedSource.domain == source.domain)
            #expect(returnedSource.runTime == source.runTime)
            #expect(returnedSource.forecastHour == source.forecastHour)
            #expect(returnedSource.validTime == source.validTime)
            #expect(returnedSource.fieldSetVersion == source.fieldSetVersion)
        }
    }

    @Test("cache rejects source metadata without a NOMADS URL")
    func cacheRejectsMissingNomadsURL() async throws {
        let source = StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoV1,
            bbox: StormSetupHrrrBoundingBox(
                around: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
            ),
            nomadsURL: nil
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(client: StubHTTPClient(), blockingWorkExecutor: blockingWork.executor)

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected a missing NOMADS URL error.")
        } catch let error as GribSubsetCacheError {
            guard case .missingNomadsURL(let returnedSource) = error else {
                Issue.record("Expected missingNomadsURL, got \(error).")
                return
            }

            #expect(returnedSource.model == source.model)
            #expect(returnedSource.product == source.product)
            #expect(returnedSource.domain == source.domain)
            #expect(returnedSource.runTime == source.runTime)
            #expect(returnedSource.forecastHour == source.forecastHour)
            #expect(returnedSource.validTime == source.validTime)
            #expect(returnedSource.fieldSetVersion == source.fieldSetVersion)
        }
    }

    @Test("cache rejects HTML or error text responses")
    func cacheRejectsHTMLResponses() async throws {
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(
                        status: 200,
                        headers: ["Content-Type": "text/html; charset=utf-8"],
                        data: Data("<html><body>Access denied</body></html>".utf8)
                    )
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = makeCache(client: client, blockingWorkExecutor: blockingWork.executor)

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected an HTML rejection error.")
        } catch let error as GribSubsetCacheError {
            guard case .rejectedTextResponse(let returnedSource, _) = error else {
                Issue.record("Expected rejectedTextResponse, got \(error).")
                return
            }

            #expect(returnedSource.model == source.model)
            #expect(returnedSource.product == source.product)
            #expect(returnedSource.domain == source.domain)
            #expect(returnedSource.runTime == source.runTime)
            #expect(returnedSource.forecastHour == source.forecastHour)
            #expect(returnedSource.validTime == source.validTime)
            #expect(returnedSource.fieldSetVersion == source.fieldSetVersion)
        }
    }

    @Test("cache rejects oversized responses")
    func cacheRejectsOversizedResponses() async throws {
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let responseData = Data(repeating: 0x41, count: 5)
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: blockingWork.executor,
            rootURL: testRootURL(),
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 4
        )

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected an oversized response error.")
        } catch let error as GribSubsetCacheError {
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
        }
    }

    @Test("corrupt cached files are invalidated and redownloaded")
    func corruptCacheEntryTriggersRedownload() async throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let initialData = Data("first-pass".utf8)
        let replacementData = Data("second-pass".utf8)
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: initialData)
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let countingExecutor = CountingPressureArtifactBlockingWorkExecutor(wrapping: blockingWork.executor)
        let cache = GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: countingExecutor,
            rootURL: rootURL,
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        let first = try await cache.loadOrFetch(sourceMetadata: source)
        try replacementData.write(to: first.localFileURL, options: [.atomic])

        let executionCountBeforeInvalidation = await countingExecutor.executionCount()
        let second = try await cache.loadOrFetch(sourceMetadata: source)
        let executionCountAfterInvalidation = await countingExecutor.executionCount()

        #expect(second.cacheHit == false)
        #expect(client.requestCount == 2)
        #expect(executionCountAfterInvalidation > executionCountBeforeInvalidation)

        let cachedData = try Data(contentsOf: second.localFileURL)
        #expect(cachedData == initialData)
    }

    @Test("metadata write failure removes both cache artifacts")
    func metadataWriteFailureRemovesBothArtifacts() async throws {
        let rootURL = testRootURL()
        let source = makeSourceMetadata(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let responseData = Data("grib-subset".utf8)
        let client = StubHTTPClient(
            plannedResponses: [
                source.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: responseData)
                )
            ]
        )
        let key = try StormSetupCacheKey(sourceMetadata: source)
        let fileURL = key.subsetFileURL(rootURL: rootURL)
        let metadataURL = key.metadataFileURL(rootURL: rootURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: true)
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let countingExecutor = CountingPressureArtifactBlockingWorkExecutor(wrapping: blockingWork.executor)
        let cache = GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: countingExecutor,
            rootURL: rootURL,
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )

        do {
            _ = try await cache.loadOrFetch(sourceMetadata: source)
            Issue.record("Expected metadata persistence to fail.")
        } catch let error as GribSubsetCacheError {
            guard case .unableToWriteCache(let path, _) = error else {
                Issue.record("Expected unableToWriteCache, got \(error).")
                return
            }
            #expect(path == fileURL)
        }

        #expect(await countingExecutor.executionCount() > 0)
        #expect(client.requestCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: metadataURL.path))
    }

    @Test("blocking critical section serializes multi-threaded work and releases after cancellation")
    func blockingCriticalSectionSerializesAndReleasesAfterCancellation() async throws {
        try await withPressureArtifactThreadPoolExecutor(numberOfThreads: 3) { executor in
            let criticalSection = BlockingWorkCriticalSection()
            let firstEntered = DispatchSemaphore(value: 0)
            let releaseFirst = DispatchSemaphore(value: 0)
            let secondDispatched = DispatchSemaphore(value: 0)
            let secondEntered = DispatchSemaphore(value: 0)

            let first = Task {
                try await executor.execute {
                    criticalSection.withLock {
                        firstEntered.signal()
                        releaseFirst.wait()
                    }
                }
            }
            #expect(try await wait(for: firstEntered, using: executor) == .success)

            let second = Task {
                try await executor.execute {
                    secondDispatched.signal()
                    criticalSection.withLock {
                        _ = secondEntered.signal()
                    }
                }
            }
            #expect(try await wait(for: secondDispatched, using: executor) == .success)
            #expect(try await wait(for: secondEntered, timeout: 0.1, using: executor) == .timedOut)

            second.cancel()
            releaseFirst.signal()
            #expect(try await wait(for: secondEntered, using: executor) == .success)
            try await first.value
            await #expect(throws: CancellationError.self) {
                try await second.value
            }

            let subsequentResult = try await executor.execute {
                criticalSection.withLock { "acquired" }
            }
            #expect(subsequentResult == "acquired")
        }
    }

    @Test("fallback downloader uses the first usable candidate in order")
    func downloaderFallsBackAcrossCandidates() async throws {
        let rootURL = testRootURL()
        let firstCandidate = HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let secondCandidate = HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12),
            forecastHour: 10
        )
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let builder = HrrrNomadsURLBuilder()
        let firstSource = builder.makeSourceMetadata(for: firstCandidate, around: centroid)
        let secondSource = builder.makeSourceMetadata(for: secondCandidate, around: centroid)
        let client = StubHTTPClient(
            plannedResponses: [
                firstSource.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 503, headers: ["Content-Type": "text/html"], data: Data("<html>down</html>".utf8))
                ),
                secondSource.nomadsURL!.absoluteString: .success(
                    HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], data: Data("grib".utf8))
                )
            ]
        )
        let blockingWork = PressureArtifactBlockingWorkTestContext()
        let cache = GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: blockingWork.executor,
            rootURL: rootURL,
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )
        let downloader = NomadsGribDownloader(cache: cache, hrrrNomadsURLBuilder: builder)
        let resolution = HrrrRunResolution(
            targetValidTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            candidates: [firstCandidate, secondCandidate]
        )

        let result = try await downloader.loadFirstAvailableSubset(for: resolution, around: centroid)

        #expect(result.cacheHit == false)
        #expect(result.source.runTime == secondCandidate.runTime)
        #expect(client.requestCount == 2)
    }

    private func makeCache(
        client: StubHTTPClient,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    ) -> GribSubsetCache {
        GribSubsetCache(
            httpClient: client,
            blockingWorkExecutor: blockingWorkExecutor,
            rootURL: testRootURL(),
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
            retentionDuration: 12 * 60 * 60,
            maximumByteCount: 1024
        )
    }

    private func wait(
        for semaphore: DispatchSemaphore,
        timeout: TimeInterval = 2,
        using executor: NIOThreadPoolPressureArtifactBlockingWorkExecutor
    ) async throws -> DispatchTimeoutResult {
        try await executor.execute {
            semaphore.wait(timeout: .now() + timeout)
        }
    }

    private func makeSourceMetadata(
        runTime: Date,
        forecastHour: Int
    ) -> StormSetupSourceMetadata {
        let candidate = HrrrRunCandidate(runTime: runTime, forecastHour: forecastHour)
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        return HrrrNomadsURLBuilder().makeSourceMetadata(for: candidate, around: centroid)
    }

    private func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("storm-setup-cache-tests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class StubHTTPClient: HTTPClient, @unchecked Sendable {
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

    func post(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers)
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

    var requestCount: Int {
        requests.count
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
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
        preconditionFailure("Unable to create UTC date for test.")
    }

    return date
}
