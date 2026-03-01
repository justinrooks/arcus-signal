@testable import App
import Foundation
import Testing

@Suite("ArcusEvent fingerprint tests")
struct ArcusEventFingerprintTests {
    private func makeEvent(
        ugcCodes: [String],
        title: String? = "Tornado Warning for Test County",
        areaDesc: String? = "Test County"
    ) -> ArcusEvent {
        ArcusEvent(
            urn: "urn:oid:test-fingerprint",
            source: .nws,
            kind: .torWarning,
            sourceURL: "https://api.weather.gov/alerts/test-fingerprint",
            vtec: nil,
            messageType: .alert,
            state: .active,
            references: [],
            sent: Date(timeIntervalSince1970: 1_708_560_000),
            effective: Date(timeIntervalSince1970: 1_708_560_060),
            onset: Date(timeIntervalSince1970: 1_708_560_120),
            expires: Date(timeIntervalSince1970: 1_708_563_600),
            ends: nil,
            lastSeenActive: Date(timeIntervalSince1970: 1_708_560_030),
            severity: .severe,
            urgency: .immediate,
            certainty: .observed,
            geometry: nil,
            ugcCodes: ugcCodes,
            h3Resolution: nil,
            h3CoverHash: nil,
            title: title,
            areaDesc: areaDesc,
            rawRef: nil
        )
    }

    @Test("Fingerprint remains stable for identical content")
    func fingerprintStableForSamePayload() throws {
        let first = makeEvent(ugcCodes: ["COC031", "COC005"])
        let second = makeEvent(ugcCodes: ["COC031", "COC005"])

        let firstHash = try first.computeContentFingerprint()
        let secondHash = try second.computeContentFingerprint()

        #expect(firstHash == secondHash)
    }

    @Test("Fingerprint normalizes UGC ordering and text whitespace")
    func fingerprintCanonicalizesUGCAndText() throws {
        let first = makeEvent(
            ugcCodes: ["  coc031", "COC005", "COC031", ""],
            title: " Tornado Warning for Test County ",
            areaDesc: " Test County "
        )
        let second = makeEvent(
            ugcCodes: ["COC005", "coc031"],
            title: "Tornado Warning for Test County",
            areaDesc: "Test County"
        )

        let firstHash = try first.computeContentFingerprint()
        let secondHash = try second.computeContentFingerprint()

        #expect(firstHash == secondHash)
    }
}
