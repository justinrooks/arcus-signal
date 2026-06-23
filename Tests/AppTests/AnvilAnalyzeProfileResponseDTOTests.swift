@testable import App
import Foundation
import Testing

@Suite("Anvil analyze profile response DTOs", .serialized)
struct AnvilAnalyzeProfileResponseDTOTests {
    @Test("response DTO round-trips")
    func responseRoundTrips() throws {
        let value = AnvilAnalyzeProfileResponse(
            status: "ok",
            diagnostics: [
                AnvilAnalyzeProfileResponseDiagnosticDTO(
                    status: "warning",
                    code: "missing_surface_moisture",
                    message: "Surface moisture inputs were unavailable; profile moisture values were used."
                ),
                AnvilAnalyzeProfileResponseDiagnosticDTO(
                    status: "info",
                    code: "analysis_complete",
                    message: "Profile analysis completed successfully."
                )
            ],
            scp: 1.7,
            stp: 2.4,
            ship: 0.6
        )

        let decoded = try roundTrip(value)

        #expect(decoded == value)
    }

    @Test("frozen JSON fixture matches the response contract")
    func fixtureMatchesContract() throws {
        let fixtureData = try loadFixture(named: "AnvilAnalyzeProfileResponse")
        let response = try decoder().decode(AnvilAnalyzeProfileResponse.self, from: fixtureData)

        #expect(response == makeResponse())

        let encoded = try encoder().encode(response)
        let encodedCanonical = try canonicalJSONString(from: encoded)
        let fixtureCanonical = try canonicalJSONString(from: fixtureData)
        #expect(encodedCanonical == fixtureCanonical)
    }

    @Test("missing optional SCP STP SHIP fields decode gracefully")
    func missingOptionalFieldsDecodeGracefully() throws {
        let json = """
        {
          "status": "degraded",
          "diagnostics": [
            {
              "status": "warning",
              "message": "SHIP was not returned for this profile."
            }
          ]
        }
        """
        let response = try decoder().decode(AnvilAnalyzeProfileResponse.self, from: Data(json.utf8))

        #expect(response.status == "degraded")
        #expect(response.diagnostics?.count == 1)
        #expect(response.diagnostics?.first?.status == "warning")
        #expect(response.diagnostics?.first?.message == "SHIP was not returned for this profile.")
        #expect(response.diagnostics?.first?.code == nil)
        #expect(response.scp == nil)
        #expect(response.stp == nil)
        #expect(response.ship == nil)
    }

    @Test("diagnostics and status decode with required fields present")
    func diagnosticsAndStatusDecode() throws {
        let response = try decoder().decode(AnvilAnalyzeProfileResponse.self, from: try loadFixture(named: "AnvilAnalyzeProfileResponse"))

        #expect(response.status == "ok")
        #expect(response.diagnostics?.map(\.status) == ["warning", "info"])
        #expect(response.diagnostics?.map(\.code) == ["missing_surface_moisture", "analysis_complete"])
    }

    private func makeResponse() -> AnvilAnalyzeProfileResponse {
        AnvilAnalyzeProfileResponse(
            status: "ok",
            diagnostics: [
                AnvilAnalyzeProfileResponseDiagnosticDTO(
                    status: "warning",
                    code: "missing_surface_moisture",
                    message: "Surface moisture inputs were unavailable; profile moisture values were used."
                ),
                AnvilAnalyzeProfileResponseDiagnosticDTO(
                    status: "info",
                    code: "analysis_complete",
                    message: "Profile analysis completed successfully."
                )
            ],
            scp: 1.7,
            stp: 2.4,
            ship: 0.6
        )
    }

    private func roundTrip<T: Codable & Equatable & Sendable>(_ value: T) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(T.self, from: data)
    }

    private func encoder() -> JSONEncoder {
        JSONEncoder()
    }

    private func decoder() -> JSONDecoder {
        JSONDecoder()
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
