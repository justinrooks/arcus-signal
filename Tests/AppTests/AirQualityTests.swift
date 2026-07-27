@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("AirNow AQI normalization")
struct AirQualityTests {
    @Test("AirNow client preserves the request and response contract")
    func airNowClientPreservesRequestAndResponseContract() async throws {
        let responseData = Data("""
        [{
          "dateObserved":"2026-07-12",
          "hourObserved":"20:00",
          "localTimeZone":"MDT",
          "parameterName":"PM2.5",
          "nowcastAQI":20,
          "aqiCategoryName":"Good"
        }]
        """.utf8)
        let httpClient = AirNowHTTPClientStub(
            plannedResponse: HTTPResponse(status: 200, headers: [:], data: responseData)
        )
        let client = DefaultAirNowClient(
            apiKey: "test-api-key",
            http: httpClient,
            baseURL: URL(string: "https://airnow.example.test")!
        )

        let observations = try await client.fetchCurrentObservations(
            latitude: 39.7392,
            longitude: -104.9903
        )

        #expect(observations.count == 1)
        #expect(observations[0].aqi == 20)
        #expect(httpClient.requests.count == 1)

        guard let request = httpClient.requests.first else {
            Issue.record("Expected one recorded AirNow request.")
            return
        }

        #expect(request.url.path == "/aq/observation/current/ziplatlong")
        #expect(request.headers["Accept"] == "application/json")

        let queryItems = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value) })
        #expect(query["format"] == "application/json")
        #expect(query["latitude"] == "39.7392")
        #expect(query["longitude"] == "-104.9903")
        #expect(query["distance"] == "25")
        #expect(query["API_KEY"] == "test-api-key")

        let failingClient = AirNowHTTPClientStub(
            plannedResponse: HTTPResponse(status: 503, headers: [:], data: nil)
        )
        let failingAirNowClient = DefaultAirNowClient(
            apiKey: "test-api-key",
            http: failingClient,
            baseURL: URL(string: "https://airnow.example.test")!
        )

        do {
            _ = try await failingAirNowClient.fetchCurrentObservations(latitude: 39.7392, longitude: -104.9903)
            Issue.record("Expected a non-2xx AirNow response to throw.")
        } catch let error as AirNowClientError {
            guard case .upstreamFailure(let status) = error else {
                Issue.record("Expected upstreamFailure, got \(error).")
                return
            }
            #expect(status == 503)
        }
    }

    @Test("provider observations decode the live AirNow payload")
    func observationsDecode() throws {
        let observations = try JSONDecoder().decode([AirNowObservation].self, from: Data("""
        [
          {
            "dateObserved":"2026-07-12",
            "hourObserved":"20:00",
            "localTimeZone":"MDT",
            "reportingAreaName":null,
            "siteID":"080310013",
            "siteName":"Denver - NJH - 14th Ave. & Albion St.",
            "parameterName":"PM2.5",
            "nowcastAQI":20,
            "aqiCategoryName":"Good",
            "reportingAgency":"Colorado Department of Public Health and Environment",
            "lookupBehavior":"Closest Reading By Pollutant",
            "consideredMonitors":"All",
            "lookupBoundary":"50 Miles"
          }
        ]
        """.utf8))

        #expect(observations.count == 1)
        #expect(observations[0].hourObserved == 20)
        #expect(observations[0].aqi == 20)
        #expect(observations[0].aqiCategoryName == "Good")
    }

    @Test("highest valid pollutant AQI becomes the normalized current value")
    func highestAQIWins() throws {
        let response = AirNowNormalizer.normalize(observations: try observations(from: """
        [
          {"dateObserved":"2026-07-12","hourObserved":"14:00","localTimeZone":"MDT","parameterName":"OZONE","nowcastAQI":72,"aqiCategoryName":"Moderate"},
          {"dateObserved":"2026-07-12","hourObserved":"15:00","localTimeZone":"MDT","parameterName":"PM2.5","nowcastAQI":121,"aqiCategoryName":"Unhealthy for Sensitive Groups"}
        ]
        """))

        #expect(response?.aqi == 121)
        #expect(response?.primaryPollutant == "PM2.5")
        #expect(response?.category?.name == "Unhealthy for Sensitive Groups")
        #expect(response?.sourceIdentifier == "airnow")
    }

    @Test("missing or invalid observations normalize to unavailable")
    func invalidObservationsAreDiscarded() throws {
        let response = AirNowNormalizer.normalize(observations: try observations(from: """
        [
          {"dateObserved":"2026-07-12","hourObserved":"14:00","nowcastAQI":-1},
          {"dateObserved":"2026-07-12","hourObserved":"25:00","nowcastAQI":41},
          {"dateObserved":"2026-07-12","hourObserved":"14:00","parameterName":"OZONE"}
        ]
        """))

        #expect(response == nil)
    }

    @Test("upstream AirNow failures normalize to unavailable")
    func upstreamAirNowFailuresNormalizeToUnavailable() async throws {
        let provider = DefaultAirQualityProvider(
            configuration: AirQualityConfiguration(airNowAPIKey: "test", cacheLifetime: 60),
            client: ThrowingAirNowClient(),
            h3Resolver: StubStormSetupH3Resolver(),
            cache: AirQualityCurrentCache(),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let response = try await provider.currentResponse(for: 617_700_169_958_293_503)

        #expect(response == nil)
    }

    private func observations(from json: String) throws -> [AirNowObservation] {
        try JSONDecoder().decode([AirNowObservation].self, from: Data(json.utf8))
    }
}

private struct ThrowingAirNowClient: AirNowClient {
    func fetchCurrentObservations(latitude: Double, longitude: Double) async throws -> [AirNowObservation] {
        _ = latitude
        _ = longitude
        throw AirNowClientError.upstreamFailure(status: 429)
    }
}

private struct StubStormSetupH3Resolver: StormSetupH3Resolving {
    func resolve(h3Cell: Int64) throws -> StormSetupResolvedH3Cell {
        _ = h3Cell
        return StormSetupResolvedH3Cell(
            h3Cell: 617_700_169_958_293_503,
            centroid: StormSetupCentroid(latitude: 39.7392, longitude: -104.9903)
        )
    }
}

private final class AirNowHTTPClientStub: HTTPClient, @unchecked Sendable {
    struct Request: Sendable {
        let url: URL
        let headers: [String: String]
    }

    private let plannedResponse: HTTPResponse
    private(set) var requests: [Request] = []

    init(plannedResponse: HTTPResponse) {
        self.plannedResponse = plannedResponse
    }

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        requests.append(Request(url: url, headers: headers))
        return plannedResponse
    }

    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func post(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func clearCache() {}
}
