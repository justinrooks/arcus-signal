import App
import Foundation
import Testing

@Suite("NWS collection envelope")
struct NwsEventDTOTests {
    private let decoder = JSONDecoder()

    @Test("accepts an explicitly empty FeatureCollection")
    func acceptsEmptyCollection() throws {
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(#"{"type":"FeatureCollection","features":[],"title":"Active Alerts","pagination":{"next":null}}"#.utf8))
        #expect(decoded.features.isEmpty)
        #expect(decoded.title == "Active Alerts")
    }

    @Test("rejects invalid collection envelopes")
    func rejectsInvalidEnvelopes() {
        let invalid = [
            #"{"type":"FeatureCollection"}"#,
            #"{"type":"FeatureCollection","features":null}"#,
            #"{"type":"upstream-error","title":"temporary failure"}"#,
            #"{"features":[]}"#,
            #"{"type":"FeatureCollection","features":{}}"#,
            #"{"type":"FeatureCollection","features":[{}]}"#,
            #"{"type":"FeatureCollection","features":["#
        ]
        for json in invalid {
            #expect(throws: (any Error).self) {
                try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
            }
        }
    }

    @Test("accepts a valid collection containing a supported alert")
    func acceptsSupportedFeature() throws {
        let json = #"{"type":"FeatureCollection","features":[{"id":"urn:oid:example","type":"Feature","properties":{"id":"https://api.weather.gov/alerts/example","areaDesc":"Test County","event":"Tornado Warning"}}],"unrelated":"ignored"}"#
        let decoded = try decoder.decode(NwsEventDTO.self, from: Data(json.utf8))
        #expect(decoded.features.count == 1)
        #expect(decoded.toArcusEvents().count == 1)
    }
}
