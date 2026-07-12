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

    private func observations(from json: String) throws -> [AirNowObservation] {
        try JSONDecoder().decode([AirNowObservation].self, from: Data(json.utf8))
    }
}
