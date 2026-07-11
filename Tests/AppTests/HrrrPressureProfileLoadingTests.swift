@testable import App
import Foundation
import Testing
import ArcusCore

@Suite("HRRR pressure profile loading", .serialized)
struct HrrrPressureProfileLoadingTests {
    @Test("loader fetches IDX inventory and pressure byte-range subsets")
    func loaderFetchesIdxInventoryAndPressureByteRangeSubsets() async throws {
        let rootURL = testRootURL()
        let candidate = HrrrRunCandidate(
            runTime: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
            forecastHour: 1,
            fieldSetVersion: .tornadoPressureV1
        )
        let sourceResolution = makePressureSourceResolution(
            candidate: candidate,
            idxAvailable: true
        )
        let inventoryText = makeEightLevelInventoryText()
        let inventory = HrrrPressureIdxInventory.parse(inventoryText)
        let selection = HrrrPressureProfileMessageSelector(
            preferredLevels: [.mb1000, .mb925, .mb850, .mb700, .mb600, .mb500, .mb400, .mb300]
        ).select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
        let payloads = plan.ranges.map { range in
            let byteCount = range.closedRange.map { Int($0.upperBound - $0.lowerBound + 1) } ?? 1
            return Data(repeating: UInt8(truncatingIfNeeded: range.inventoryIndex), count: byteCount)
        }
        let client = PressureProfileStubHTTPClient(
            responses: makePlannedResponses(
                sourceResolution: sourceResolution,
                plan: plan,
                idxBody: Data(inventoryText.utf8),
                payloads: payloads
            )
        )
        try await withPressureArtifactThreadPoolExecutor { blockingWorkExecutor in
            let subsetCache = HrrrPressureSubsetGribCache(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: rootURL,
                dateProvider: PreviewFixedStormSetupDateProvider(nowDate: previewMakeUTCDate(year: 2026, month: 6, day: 3, hour: 22)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )
            let loader = DefaultHrrrPressureProfileLoader(
                httpClient: client,
                subsetCache: subsetCache,
                fieldSampler: PreviewStubStormSetupFieldSampler { subset, centroid in
                    #expect(subset.cacheHit == false)
                    #expect(centroid == StormSetupCentroid(latitude: 39.7825, longitude: -104.4661))
                    return previewMakeEightLevelPressureSamples()
                }
            )

            let result = try await loader.loadPressureProfile(
                for: sourceResolution,
                centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
                surfaceHeightMslM: nil
            )

            let idxURL = try #require(sourceResolution.source.idxURL)
            let gribURL = try #require(sourceResolution.source.primaryDownloadURL)
            #expect(result.selection.selectedMessages.count == 40)
            #expect(result.byteRangePlan.ranges.count == 40)
            #expect(result.subsetCacheResult.cacheHit == false)
            #expect(result.groupedProfile.retainedLevels.count == 8)
            #expect(result.selection.requestedLevels == StormSetupPressureLevel.preferredDescending)
            #expect(client.requests.contains(where: { $0.url == idxURL }))
            #expect(client.requests.filter { $0.url == gribURL }.count == 40)
            #expect(client.requests.filter { $0.url == gribURL && $0.headers["Range"] == nil }.isEmpty)
            #expect(result.groupedProfile.missingLevels.isEmpty == false)
        }
    }

    private func makePlannedResponses(
        sourceResolution: HrrrPressureDirectObjectResolution,
        plan: HrrrGribByteRangePlan,
        idxBody: Data,
        payloads: [Data]
    ) -> [String: HTTPResponse] {
        var responses: [String: HTTPResponse] = [:]
        if let idxURL = sourceResolution.source.idxURL {
            responses[idxURL.absoluteString] = HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                data: idxBody
            )
        }

        for (range, payload) in zip(plan.ranges, payloads) {
            let key = sourceResolution.source.primaryDownloadURL!.absoluteString + "|" + range.httpRangeHeaderValue
            let contentRange = range.closedRange.map { "bytes \($0.lowerBound)-\($0.upperBound)/20" } ?? "bytes 16-19/20"
            responses[key] = HTTPResponse(
                status: 206,
                headers: [
                    "Content-Type": "application/octet-stream",
                    "Content-Range": contentRange
                ],
                data: payload
            )
        }

        return responses
    }

    private func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("hrrr-pressure-profile-loader-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeEightLevelInventoryText() -> String {
        """
        1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
        2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
        3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
        4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
        5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
        6:20:d=2026060313:HGT:925 mb:9 hour fcst:
        7:24:d=2026060313:TMP:925 mb:9 hour fcst:
        8:28:d=2026060313:DPT:925 mb:9 hour fcst:
        9:32:d=2026060313:UGRD:925 mb:9 hour fcst:
        10:36:d=2026060313:VGRD:925 mb:9 hour fcst:
        11:40:d=2026060313:HGT:850 mb:9 hour fcst:
        12:44:d=2026060313:TMP:850 mb:9 hour fcst:
        13:48:d=2026060313:DPT:850 mb:9 hour fcst:
        14:52:d=2026060313:UGRD:850 mb:9 hour fcst:
        15:56:d=2026060313:VGRD:850 mb:9 hour fcst:
        16:60:d=2026060313:HGT:700 mb:9 hour fcst:
        17:64:d=2026060313:TMP:700 mb:9 hour fcst:
        18:68:d=2026060313:DPT:700 mb:9 hour fcst:
        19:72:d=2026060313:UGRD:700 mb:9 hour fcst:
        20:76:d=2026060313:VGRD:700 mb:9 hour fcst:
        21:80:d=2026060313:HGT:600 mb:9 hour fcst:
        22:84:d=2026060313:TMP:600 mb:9 hour fcst:
        23:88:d=2026060313:DPT:600 mb:9 hour fcst:
        24:92:d=2026060313:UGRD:600 mb:9 hour fcst:
        25:96:d=2026060313:VGRD:600 mb:9 hour fcst:
        26:100:d=2026060313:HGT:500 mb:9 hour fcst:
        27:104:d=2026060313:TMP:500 mb:9 hour fcst:
        28:108:d=2026060313:DPT:500 mb:9 hour fcst:
        29:112:d=2026060313:UGRD:500 mb:9 hour fcst:
        30:116:d=2026060313:VGRD:500 mb:9 hour fcst:
        31:120:d=2026060313:HGT:400 mb:9 hour fcst:
        32:124:d=2026060313:TMP:400 mb:9 hour fcst:
        33:128:d=2026060313:DPT:400 mb:9 hour fcst:
        34:132:d=2026060313:UGRD:400 mb:9 hour fcst:
        35:136:d=2026060313:VGRD:400 mb:9 hour fcst:
        36:140:d=2026060313:HGT:300 mb:9 hour fcst:
        37:144:d=2026060313:TMP:300 mb:9 hour fcst:
        38:148:d=2026060313:DPT:300 mb:9 hour fcst:
        39:152:d=2026060313:UGRD:300 mb:9 hour fcst:
        40:156:d=2026060313:VGRD:300 mb:9 hour fcst:
        41:180:d=2026060313:HGT:200 mb:9 hour fcst:
        """
    }
}

private func makePressureSourceResolution(
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

private final class PressureProfileStubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let url: URL
        let headers: [String: String]
    }

    private let responses: [String: HTTPResponse]
    private(set) var requests: [Request] = []

    init(responses: [String: HTTPResponse]) {
        self.responses = responses
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        requests.append(Request(url: url, headers: headers))
        let key = url.absoluteString + "|" + (headers["Range"] ?? "")
        guard let response = responses[key] ?? responses[url.absoluteString] else {
            throw URLError(.badServerResponse)
        }

        return response
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
}
