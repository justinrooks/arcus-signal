@testable import App
import Foundation
import Testing
import Vapor
import ArcusCore

@Suite("HRRR pressure byte-range downloader", .serialized)
struct HrrrPressureByteRangeDownloaderTests {
    @Test("downloader sends exact range headers and concatenates bodies in order")
    func downloaderSendsExactRangeHeadersAndConcatenatesBodiesInOrder() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let inventory = HrrrPressureIdxInventory.parse(
                """
                1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
                2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
                3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
                4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
                5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
                6:20:d=2026060313:HGT:925 mb:9 hour fcst:
                """
            )
            let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
            let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
            let client = PressureRangeStubHTTPClient(
                plannedResponses: Dictionary(uniqueKeysWithValues: zip(plan.ranges, [
                    makeResponse(status: 206, contentRange: "bytes 0-3/20", body: Data("hgt-".utf8)),
                    makeResponse(status: 206, contentRange: "bytes 4-7/20", body: Data("tmp-".utf8)),
                    makeResponse(status: 206, contentRange: "bytes 8-11/20", body: Data("dpt-".utf8)),
                    makeResponse(status: 206, contentRange: "bytes 12-15/20", body: Data("ugrd".utf8)),
                    makeResponse(status: 206, contentRange: "bytes 16-19/20", body: Data("vgrd".utf8))
                ]).map { range, response in
                    (source.primaryDownloadURL!.absoluteString + "|" + range.httpRangeHeaderValue, response)
                })
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                requestTimeoutSeconds: 17
            )

            let result = try await downloader.download(sourceMetadata: source, byteRangePlan: plan)

            #expect(client.requestCount == 5)
            #expect(client.recordedHeaders.map { $0["Range"] } == plan.ranges.map(\.httpRangeHeaderValue))
            #expect(client.recordedTimeouts == Array(repeating: 17, count: plan.ranges.count))
            #expect(result.byteSize == 20)
            #expect(result.data == Data("hgt-tmp-dpt-ugrdvgrd".utf8))
            #expect(result.checksumSHA256 == StableContentHasher.sha256Hex(of: Data("hgt-tmp-dpt-ugrdvgrd".utf8)))
        }
    }

    @Test("downloader rejects range responses that are not partial content")
    func downloaderRejectsRangeIgnored200Responses() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 200,
                        contentRange: nil,
                        body: Data("whole-file".utf8)
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .serverIgnoredRange(let returnedSource, let status) = error else {
                    Issue.record("Expected serverIgnoredRange, got \(error).")
                    return
                }

                #expect(returnedSource == source)
                #expect(status == 200)
            }
        }
    }

    @Test("downloader validates matching Content-Range values")
    func downloaderValidatesContentRangeValues() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 10-20/999",
                        body: Data("partial-body".utf8)
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .mismatchedContentRange(let returnedSource, _, let expected, let actual) = error else {
                    Issue.record("Expected mismatchedContentRange, got \(error).")
                    return
                }

                #expect(returnedSource == source)
                #expect(expected == plan.ranges[0].httpRangeHeaderValue)
                #expect(actual == "bytes 10-20/999")
            }
        }
    }

    @Test("downloader rejects partial content responses missing Content-Range")
    func downloaderRejectsPartialContentResponsesMissingContentRange() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: nil,
                        body: Data("partial-body".utf8)
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .missingContentRange(let returnedSource, _) = error else {
                    Issue.record("Expected missingContentRange, got \(error).")
                    return
                }

                #expect(returnedSource == source)
            }
        }
    }

    @Test("downloader rejects 416 responses")
    func downloaderRejects416Responses() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(status: 416, contentRange: nil, body: Data())
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .rangeNotSatisfiable(let returnedSource) = error else {
                    Issue.record("Expected rangeNotSatisfiable, got \(error).")
                    return
                }

                #expect(returnedSource == source)
            }
        }
    }

    @Test("downloader rejects empty range bodies")
    func downloaderRejectsEmptyRangeBodies() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 0-0/1",
                        body: Data()
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .emptyResponseBody(let returnedSource, _) = error else {
                    Issue.record("Expected emptyResponseBody, got \(error).")
                    return
                }

                #expect(returnedSource == source)
            }
        }
    }

    @Test("downloader rejects obvious text or HTML range bodies")
    func downloaderRejectsTextOrHTMLRangeBodies() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let plan = makeSingleRangePlan()
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 0-18/19",
                        body: Data("<html>forbidden</html>".utf8),
                        contentType: "text/html; charset=utf-8"
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            await assertThrowsDownloaderError {
                try await downloader.download(sourceMetadata: source, byteRangePlan: plan)
            } verify: { error in
                guard case .rejectedTextResponse(let returnedSource, _, _) = error else {
                    Issue.record("Expected rejectedTextResponse, got \(error).")
                    return
                }

                #expect(returnedSource == source)
            }
        }
    }

    @Test("downloader accepts open-ended terminal ranges with valid partial content")
    func downloaderAcceptsOpenEndedTerminalRanges() async throws {
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let source = makeSourceMetadata()
            let inventory = HrrrPressureIdxInventory.parse(
                """
                1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
                2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
                3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
                4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
                5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
                """
            )
            let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
            let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
            let client = PressureRangeStubHTTPClient(
                plannedResponses: [
                    plan.ranges[0].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 0-3/20",
                        body: Data("hgt-".utf8)
                    ),
                    plan.ranges[1].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 4-7/20",
                        body: Data("tmp-".utf8)
                    ),
                    plan.ranges[2].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 8-11/20",
                        body: Data("dpt-".utf8)
                    ),
                    plan.ranges[3].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 12-15/20",
                        body: Data("ugrd".utf8)
                    ),
                    plan.ranges[4].httpRangeHeaderValue: makeResponse(
                        status: 206,
                        contentRange: "bytes 16-19/20",
                        body: Data("vgrd".utf8)
                    )
                ]
            )
            let downloader = HrrrPressureByteRangeDownloader(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor
            )

            let result = try await downloader.download(sourceMetadata: source, byteRangePlan: plan)

            #expect(plan.ranges.last?.httpRangeHeaderValue == "bytes=16-")
            #expect(result.byteSize == 20)
            #expect(result.data == Data("hgt-tmp-dpt-ugrdvgrd".utf8))
        }
    }

    @Test("downloader terminates a stalled range request through its configured deadline")
    func downloaderTerminatesStalledRangeRequestThroughConfiguredDeadline() async throws {
        let application = try await Application.make(.testing)
        do {
            application.clients.use { application in
                DeadlineDrivenTestVaporClient(eventLoop: application.eventLoopGroup.next())
            }
            let client = VaporApplicationHTTPClient(application: application, retryDelaysSeconds: [0])
            do {
                _ = try await client.get(
                    URL(string: "https://pressure-artifact.test/stalled")!,
                    headers: [:],
                    timeoutSeconds: 0.001
                )
                Issue.record("Expected the stalled request to complete through the configured deadline.")
            } catch let error as URLError {
                #expect(error.code == .timedOut)
            }
            try await application.asyncShutdown()
        } catch {
            try? await application.asyncShutdown()
            throw error
        }
    }

    private func makeSingleRangePlan() -> HrrrGribByteRangePlan {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
            3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
            4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
            5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
            """
        )
        let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
        return HrrrGribByteRangePlan(ranges: [plan.ranges[0]])
    }

    private func makeSourceMetadata() -> StormSetupSourceMetadata {
        HrrrPressureDirectObjectURLBuilder().makeSourceMetadata(
            for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV1
            )
        )
    }

    private func makeResponse(
        status: Int,
        contentRange: String?,
        body: Data,
        contentType: String = "application/octet-stream"
    ) -> HTTPResponse {
        var headers = ["Content-Type": contentType]
        if let contentRange {
            headers["Content-Range"] = contentRange
        }
        return HTTPResponse(status: status, headers: headers, data: body)
    }

    private func assertThrowsDownloaderError(
        _ operation: @escaping @Sendable () async throws -> Void,
        verify: @escaping (HrrrPressureByteRangeDownloaderError) -> Void
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected a downloader error.")
        } catch let error as HrrrPressureByteRangeDownloaderError {
            verify(error)
        } catch {
            Issue.record("Expected a downloader error, got \(error).")
        }
    }
}

final class PressureRangeStubHTTPClient: App.HTTPClient, @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let url: URL
        let headers: [String: String]
        let timeoutSeconds: TimeInterval?
    }

    private let plannedResponses: [String: HTTPResponse]
    private(set) var requests: [Request] = []

    init(plannedResponses: [String: HTTPResponse] = [:]) {
        self.plannedResponses = plannedResponses
    }

    func get(_ url: URL, headers: [String : String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        requests.append(Request(url: url, headers: headers, timeoutSeconds: timeoutSeconds))
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
    var recordedHeaders: [[String: String]] { requests.map(\.headers) }
    var recordedTimeouts: [TimeInterval?] { requests.map(\.timeoutSeconds) }
}

private struct DeadlineDrivenTestVaporClient: Vapor.Client {
    let eventLoop: any EventLoop

    func delegating(to eventLoop: any EventLoop) -> any Vapor.Client {
        DeadlineDrivenTestVaporClient(eventLoop: eventLoop)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        guard let timeout = request.timeout else {
            return eventLoop.makeFailedFuture(URLError(.cannotConnectToHost))
        }

        let promise = eventLoop.makePromise(of: ClientResponse.self)
        _ = eventLoop.scheduleTask(in: timeout) {
            promise.fail(URLError(.timedOut))
        }
        return promise.futureResult
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
        preconditionFailure("Unable to create UTC date for pressure byte-range tests.")
    }

    return date
}
