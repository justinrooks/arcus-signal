@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("AirNow AQI normalization")
struct AirQualityTests {
    @Test("cache reclaims expired entries during bounded maintenance")
    func cacheReclaimsExpiredEntries() async {
        let cache = AirQualityCurrentCache()
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for key in 0..<10_000 {
            await cache.store(nil, for: Int64(key), expiresAt: start.addingTimeInterval(1), now: start)
        }
        let expired = start.addingTimeInterval(1)
        for key in 0..<10_000 {
            #expect(await cache.response(for: Int64(key), now: expired) == nil)
        }
        #expect(await cache.entryCount() == 0)
    }

    @Test("cache preserves fresh and negative hits while bounding churn")
    func cacheBoundsChurnAndPreservesHits() async {
        let cache = AirQualityCurrentCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for key in 0..<AirQualityCurrentCache.capacity {
            await cache.store(nil, for: Int64(key), expiresAt: now.addingTimeInterval(60), now: now)
        }
        for _ in 0..<100 { _ = await cache.response(for: 0, now: now) }
        for key in AirQualityCurrentCache.capacity..<AirQualityCurrentCache.capacity + 500 {
            await cache.store(nil, for: Int64(key), expiresAt: now.addingTimeInterval(60), now: now)
        }
        #expect(await cache.entryCount() == AirQualityCurrentCache.capacity)
        #expect(await cache.response(for: 0, now: now) == .some(nil))
        #expect(await cache.response(for: 1_499, now: now) == .some(nil))
        await cache.store(nil, for: 1_499, expiresAt: now.addingTimeInterval(120), now: now)
        #expect(await cache.response(for: 1_499, now: now.addingTimeInterval(61)) == .some(nil))
    }

    @Test("cache remains bounded under concurrent actor access")
    func cacheConcurrentAccessRemainsBounded() async {
        let cache = AirQualityCurrentCache()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        await withTaskGroup(of: Void.self) { group in
            for key in 0..<2_000 {
                group.addTask {
                    await cache.store(nil, for: Int64(key), expiresAt: now.addingTimeInterval(60), now: now)
                    _ = await cache.response(for: Int64(key), now: now)
                }
            }
        }
        #expect(await cache.entryCount() <= AirQualityCurrentCache.capacity)
    }

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

        #expect(observations.observations.count == 1)
        #expect(observations.observations[0].aqi == 20)
        #expect(httpClient.requests.count == 1)

        guard let request = httpClient.requests.first else {
            Issue.record("Expected one recorded AirNow request.")
            return
        }

        #expect(request.url.path == "/aq/observation/current/ziplatlong")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.timeoutSeconds == nil)

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
    func fetchCurrentObservations(latitude: Double, longitude: Double) async throws -> AirNowObservationsResponse {
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
        let timeoutSeconds: TimeInterval?
    }

    private let plannedResponse: HTTPResponse
    private(set) var requests: [Request] = []

    init(plannedResponse: HTTPResponse) {
        self.plannedResponse = plannedResponse
    }

    func get(_ url: URL, headers: [String: String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        requests.append(Request(url: url, headers: headers, timeoutSeconds: timeoutSeconds))
        return plannedResponse
    }

    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func post(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func clearCache() {}
}
