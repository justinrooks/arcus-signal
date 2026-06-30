@testable import App
import Foundation
import Testing

@Suite("Anvil analyze profile response DTOs", .serialized)
struct AnvilAnalyzeProfileResponseDTOTests {
    @Test("response DTO round-trips")
    func responseRoundTrips() throws {
        let value = makeResponse()

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

    @Test("missing optional nested fields decode gracefully")
    func missingOptionalFieldsDecodeGracefully() throws {
        let json = """
        {
          "effectiveLayer": {
            "status": "notFound"
          },
          "stormMotion": {
            "status": "notComputed"
          },
          "quality": {
            "profileLevelCount": 0,
            "warnings": []
          }
        }
        """
        let response = try decoder().decode(AnvilAnalyzeProfileResponse.self, from: Data(json.utf8))

        #expect(response.effectiveLayer.status == "notFound")
        #expect(response.effectiveLayer.basePressureMb == nil)
        #expect(response.effectiveLayer.topPressureMb == nil)
        #expect(response.effectiveLayer.baseMetersAgl == nil)
        #expect(response.effectiveLayer.topMetersAgl == nil)
        #expect(response.stormMotion.status == "notComputed")
        #expect(response.stormMotion.bunkersRight == nil)
        #expect(response.mucape == nil)
        #expect(response.mlcape == nil)
        #expect(response.mlcin == nil)
        #expect(response.mllclMetersAgl == nil)
        #expect(response.effectiveSrh == nil)
        #expect(response.effectiveBulkShearMs == nil)
        #expect(response.scp == nil)
        #expect(response.stpCin == nil)
        #expect(response.stpFixed == nil)
        #expect(response.ship == nil)
        #expect(response.quality.profileLevelCount == 0)
        #expect(response.quality.warnings.isEmpty)
    }

    @Test("nested status fields decode with required shape present")
    func nestedStatusFieldsDecode() throws {
        let response = try decoder().decode(
            AnvilAnalyzeProfileResponse.self,
            from: try loadFixture(named: "AnvilAnalyzeProfileResponse")
        )

        #expect(response.effectiveLayer.status == "found")
        #expect(response.stormMotion.status == "computed")
        #expect(response.stormMotion.bunkersRight != nil)
        #expect(response.quality.profileLevelCount == 20)
        #expect(response.quality.warnings == ["dew point greater than temperature at one or more levels"])
    }

    private func makeResponse() -> AnvilAnalyzeProfileResponse {
        AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: "found",
                basePressureMb: 1000,
                topPressureMb: 925,
                baseMetersAgl: 0,
                topMetersAgl: 690
            ),
            stormMotion: AnvilStormMotionDTO(
                status: "computed",
                bunkersRight: AnvilBunkersRightStormMotionDTO(
                    uKt: 36.80394762849837,
                    vKt: 13.53066796460426,
                    speedKt: 39.21236458834915,
                    directionTowardDeg: 69.81446460119884,
                    uMs: 18.933570033795217,
                    vMs: 6.960770950382875,
                    speedMs: 20.172565688288692
                )
            ),
            mucape: 362.1018454649957,
            mlcape: 191.7304143918497,
            mlcin: -221.93726424748172,
            mllclMetersAgl: 1179.4130766012365,
            effectiveSrh: 29.42420403684148,
            effectiveBulkShearMs: 30.134722226263612,
            scp: 0.2130911716615775,
            stpCin: 0.0,
            stpFixed: 0.10598607777331374,
            ship: 0.02328171526804675,
            quality: AnvilQualityDTO(
                profileLevelCount: 20,
                warnings: ["dew point greater than temperature at one or more levels"]
            )
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
