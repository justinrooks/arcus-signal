@testable import App
import Foundation
import Testing

@Suite("Anvil analyze profile DTOs", .serialized)
struct AnvilAnalyzeProfileDTOTests {
    @Test("location DTO round-trips")
    func locationRoundTrips() throws {
        let value = AnvilLocationDTO(lat: 39.7392, lon: -104.9903, h3: "882681b59fffffff")

        let decoded = try roundTrip(value)

        #expect(decoded.lat == value.lat)
        #expect(decoded.lon == value.lon)
        #expect(decoded.h3 == value.h3)
    }

    @Test("profile DTO round-trips")
    func profileRoundTrips() throws {
        let value = AnvilProfileDTO(
            pressureMb: [1000, 925, 850],
            heightMslM: [1560, 780, 1450],
            temperatureC: [28.4, 22.8, 17.5],
            dewpointC: [12.3, 10.1, 11.2],
            uWindMs: [-2.1, -5.4, -6.25],
            vWindMs: [4.6, 7.9, 8.75]
        )

        let decoded = try roundTrip(value)

        #expect(decoded == value)
    }

    @Test("anvil analyze profile request round-trips")
    func requestRoundTrips() throws {
        let value = makeRequest()

        let decoded = try roundTrip(value)

        #expect(decoded.runTime == value.runTime)
        #expect(decoded.forecastHour == value.forecastHour)
        #expect(decoded.validTime == value.validTime)
        #expect(decoded.location.lat == value.location.lat)
        #expect(decoded.location.lon == value.location.lon)
        #expect(decoded.location.h3 == value.location.h3)
        #expect(decoded.profile == value.profile)
    }

    @Test("frozen JSON fixture matches the request contract")
    func fixtureMatchesContract() throws {
        let fixtureData = try loadFixture(named: "AnvilAnalyzeProfileRequest")
        let request = try decoder().decode(AnvilAnalyzeProfileRequest.self, from: fixtureData)

        #expect(request == makeRequest())

        let encoded = try encoder().encode(request)
        let encodedCanonical = try canonicalJSONString(from: encoded)
        let fixtureCanonical = try canonicalJSONString(from: fixtureData)
        #expect(encodedCanonical == fixtureCanonical)
    }

    private func makeRequest() -> AnvilAnalyzeProfileRequest {
        AnvilAnalyzeProfileRequest(
            runTime: isoDate("2026-06-19T22:00:00Z"),
            forecastHour: 3,
            validTime: isoDate("2026-06-20T01:00:00Z"),
            location: AnvilLocationDTO(
                lat: 39.7392,
                lon: -104.9903,
                h3: "882681b59fffffff"
            ),
            profile: AnvilProfileDTO(
                pressureMb: [1000, 925, 850],
                heightMslM: [1560, 780, 1450],
                temperatureC: [28.4, 22.8, 17.5],
                dewpointC: [12.3, 10.1, 11.2],
                uWindMs: [-2.1, -5.4, -6.25],
                vWindMs: [4.6, 7.9, 8.75]
            )
        )
    }

    private func roundTrip<T: Codable & Equatable & Sendable>(_ value: T) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(T.self, from: data)
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }

    private func loadFixture(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw TestFixtureError.missingFixture(name)
        }
        return try Data(contentsOf: url)
    }

    private func canonicalJSONString(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let string = String(data: canonical, encoding: .utf8) else {
            throw TestFixtureError.unableToDecodeCanonicalJSON
        }
        return string
    }
}

private enum TestFixtureError: Error {
    case missingFixture(String)
    case unableToDecodeCanonicalJSON
}
