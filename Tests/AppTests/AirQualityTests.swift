@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("AirNow AQI normalization")
struct AirQualityTests {
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
