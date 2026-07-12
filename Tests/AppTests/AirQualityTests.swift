@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("AirNow AQI normalization")
struct AirQualityTests {
    @Test("provider observations decode AirNow wire keys")
    func observationsDecode() throws {
        let observations = try JSONDecoder().decode([AirNowObservation].self, from: Data("""
        [{"DateObserved":"2026-07-12","HourObserved":14,"LocalTimeZone":"America/Denver","ParameterName":"PM2.5","AQI":87,"Category":{"Number":2,"Name":"Moderate"}}]
        """.utf8))

        #expect(observations.count == 1)
        #expect(observations[0].aqi == 87)
        #expect(observations[0].category?.name == "Moderate")
    }

    @Test("highest valid pollutant AQI becomes the normalized current value")
    func highestAQIWins() throws {
        let response = AirNowNormalizer.normalize(observations: try observations(from: """
        [
          {"DateObserved":"2026-07-12","HourObserved":14,"LocalTimeZone":"America/Denver","ParameterName":"OZONE","AQI":72,"Category":{"Number":2,"Name":"Moderate"}},
          {"DateObserved":"2026-07-12","HourObserved":15,"LocalTimeZone":"America/Denver","ParameterName":"PM2.5","AQI":121,"Category":{"Number":3,"Name":"Unhealthy for Sensitive Groups"}}
        ]
        """))

        #expect(response?.aqi == 121)
        #expect(response?.primaryPollutant == "PM2.5")
        #expect(response?.category?.identifier == 3)
        #expect(response?.sourceIdentifier == "airnow")
    }

    @Test("missing or invalid observations normalize to unavailable")
    func invalidObservationsAreDiscarded() throws {
        let response = AirNowNormalizer.normalize(observations: try observations(from: """
        [
          {"DateObserved":"2026-07-12","HourObserved":14,"AQI":-1},
          {"DateObserved":"2026-07-12","HourObserved":25,"AQI":41},
          {"DateObserved":"2026-07-12","HourObserved":14,"ParameterName":"OZONE"}
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
