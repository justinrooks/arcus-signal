@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("Meso notification composer tests")
struct MesoNotificationComposerTests {
    private let composer = MesoNotificationComposer()

    private func discussion(
        probability: Double? = nil,
        probabilityText: String = "Unknown",
        threats: MesoscaleDiscussionThreats? = nil
    ) -> MesoscaleDiscussionPayload {
        .init(
            number: 1234,
            title: "Mesoscale Discussion 1234",
            sourceURL: URL(string: "https://www.spc.noaa.gov/products/md/md1234.html")!,
            issued: Date(timeIntervalSince1970: 1_750_000_000),
            validStart: Date(timeIntervalSince1970: 1_750_000_000),
            validEnd: Date(timeIntervalSince1970: 1_750_360_000),
            areasAffected: "Eastern Colorado",
            summary: "Storms are developing.",
            concerning: nil,
            watchProbability: probability,
            watchProbabilityText: probabilityText,
            threats: threats,
            coordinates: []
        )
    }

    @Test("Numeric watch probability and place label match app copy")
    func numericProbabilityAndPlace() {
        let result = composer.buildPreviewNotification(
            for: discussion(probability: 30, probabilityText: "30"),
            placeLabel: "Oklahoma City, OK"
        )

        #expect(result.title == "Mesoscale Discussion for Oklahoma City, OK")
        #expect(result.subTitle == "Watch issuance chance: 30%")
    }

    @Test("Unlikely source text is retained without exposing unknown values")
    func unlikelyTextAndMissingPlace() {
        let unknown = composer.buildPreviewNotification(for: discussion(probabilityText: " Unknown "))
        #expect(unknown.subTitle == "Watch potential not specified")

        let result = composer.buildPreviewNotification(
            for: discussion(probabilityText: "Unlikely", threats: .init(
                peakWindMPH: nil,
                hailRangeInches: nil,
                tornadoStrength: "unknown"
            )),
            placeLabel: " Unknown "
        )

        #expect(result.title == "Mesoscale Discussion for your area")
        #expect(result.subTitle == "Watch possible: Unlikely")
        #expect(result.body == "SPC is monitoring storms near your area. Open SkyAware for the full discussion.")
        #expect(!result.title.localizedCaseInsensitiveContains("unknown"))
        #expect(!result.subTitle.localizedCaseInsensitiveContains("unknown"))
        #expect(!result.body.localizedCaseInsensitiveContains("unknown"))
    }

    @Test("Wind hail and tornado concerns include available detail")
    func threatSummary() {
        let result = composer.buildPreviewNotification(
            for: discussion(threats: .init(
                peakWindMPH: 35,
                hailRangeInches: 2,
                tornadoStrength: "EF2+"
            ))
        )

        #expect(result.body == "Main concerns: damaging wind, large hail, and isolated tornadoes. Gusts near 35 mph; hail up to 2\".")
    }

    @Test("Sparse threat data uses the concise fallback")
    func sparseThreatFallback() {
        let result = composer.buildPreviewNotification(
            for: discussion(probability: 35, probabilityText: "35", threats: .init(
                peakWindMPH: nil,
                hailRangeInches: nil,
                tornadoStrength: " "
            )),
            placeLabel: "  "
        )

        #expect(result.body == "SPC is monitoring storms near your area. Open SkyAware for the full discussion.")
        #expect(result.title == "Mesoscale Discussion for your area")
    }

    @Test("Typed APNs payload identifies a meso product while legacy alert decoding remains supported")
    func typedPayloadAndDebugSubject() throws {
        let subject = NotificationSubject.spcMeso(issueYear: 2025, number: 1234)
        let payload = try #require(HotAlertAPNsPayload(
            productKind: .mesoscaleDiscussion,
            resourceID: subject.productID
        ))
        let encoder = makeAPNSRequestEncoder()
        let encoded = try encoder.encode(payload)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?[HotAlertAPNsPayload.productKindKey] as? String == "mesoscaleDiscussion")
        #expect(object?[HotAlertAPNsPayload.resourceIDKey] as? String == "SPC-MD-2025-1234")
        #expect(object?[HotAlertAPNsPayload.arcusAlertIDKey] == nil)

        let legacyData = try JSONSerialization.data(withJSONObject: [
            HotAlertAPNsPayload.arcusAlertIDKey: "11111111-2222-3333-4444-555555555555"
        ])
        let legacyPayload = try JSONDecoder().decode(HotAlertAPNsPayload.self, from: legacyData)
        #expect(legacyPayload.productKind == .nwsAlert)
        #expect(legacyPayload.resolvedAlertID == "11111111-2222-3333-4444-555555555555")

        let preview = composer.buildPreviewNotification(for: discussion())
        let debug = NotificationDebugModel(
            seriesID: subject.nwsSeriesID,
            revisionUrn: subject.revisionID,
            mode: NotificationTargetMode.h3.rawValue,
            reason: NotificationReason.new.rawValue,
            recordKind: .previewNoCandidates,
            title: preview.title,
            subtitle: preview.subTitle,
            body: preview.body,
            subject: subject
        )
        #expect(debug.subject == subject)
        #expect(debug.title == preview.title)
    }
}
