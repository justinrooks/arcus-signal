@testable import App
import Foundation
import Testing

@Suite("NWS client", .serialized)
struct NwsClientTests {
    @Test("active alerts request builds the supported event filter")
    func activeAlertsRequestBuildsSupportedEventFilter() async throws {
        let httpClient = NwsClientStubHTTPClient(
            plannedResponse: HTTPResponse(
                status: 200,
                headers: [:],
                data: Data(#"{"type":"FeatureCollection","features":[]}"#.utf8)
            )
        )

        let client = NwsHttpClient(http: httpClient)
        _ = try await client.fetchActiveAlertsJsonData()

        #expect(httpClient.requestCount == 1)

        guard let recordedURL = httpClient.recordedURLs.first else {
            Issue.record("Expected one recorded request URL.")
            return
        }

        #expect(recordedURL.path == "/alerts/active")

        let components = URLComponents(url: recordedURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        #expect(queryItems.first(where: { $0.name == "status" })?.value == "actual")
        #expect(queryItems.first(where: { $0.name == "region_type" })?.value == "land")

        let eventValues = queryItems
            .first(where: { $0.name == "event" })?
            .value?
            .split(separator: ",")
            .map(String.init) ?? []

        #expect(eventValues.contains("Ashfall Advisory"))
        #expect(eventValues.contains("Ashfall Warning"))
        #expect(eventValues.contains("Blowing Dust Advisory"))
        #expect(eventValues.contains("Blowing Dust Warning"))
        #expect(eventValues.contains("Dust Advisory"))
        #expect(eventValues.contains("Dust Storm Warning"))
        #expect(eventValues.contains("Special Weather Statement"))
        #expect(eventValues.contains("Wind Advisory"))
    }
}

private final class NwsClientStubHTTPClient: HTTPClient, @unchecked Sendable {
    let plannedResponse: HTTPResponse
    private(set) var recordedURLs: [URL] = []

    init(plannedResponse: HTTPResponse) {
        self.plannedResponse = plannedResponse
    }

    func get(_ url: URL, headers: [String : String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        _ = timeoutSeconds
        recordedURLs.append(url)
        return plannedResponse
    }

    func head(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        recordedURLs.append(url)
        return plannedResponse
    }

    func post(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        recordedURLs.append(url)
        return plannedResponse
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        recordedURLs.append(url)
        return plannedResponse
    }

    func clearCache() {}

    var requestCount: Int {
        recordedURLs.count
    }
}
