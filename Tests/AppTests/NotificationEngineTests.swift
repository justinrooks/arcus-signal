@testable import App
import Foundation
import Testing

@Suite("Notification engine tests")
struct NotificationEngineTests {
    private let engine = NotificationEngine()

    private func makeSeries(
        event: String,
        severity: String = "severe",
        urgency: String = "immediate",
        certainty: String = "observed",
        title: String? = nil,
        headline: String? = nil
    ) -> ArcusSeriesModel {
        ArcusSeriesModel(
            source: "nws",
            event: event,
            sourceURL: "https://api.weather.gov/alerts/test",
            currentRevisionUrn: "urn:oid:test",
            currentRevisionSent: Date(timeIntervalSince1970: 1_710_000_000),
            messageType: "alert",
            contentFingerprint: "fingerprint",
            state: "active",
            lastSeenActive: Date(timeIntervalSince1970: 1_710_000_000),
            severity: severity,
            urgency: urgency,
            certainty: certainty,
            ugcCodes: [],
            title: title,
            headline: headline
        )
    }

    private func makePayload(
        mode: NotificationTargetMode,
        reason: NotificationReason
    ) -> NotificationSendJobPayload {
        .init(
            seriesId: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            revisionUrn: "urn:oid:test",
            mode: mode,
            reason: reason
        )
    }

    private func makeCandidate(
        countyLabel: String? = nil,
        fireZoneLabel: String? = nil
    ) -> NotificationCandidate {
        .init(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            apnsToken: "token",
            apnsEnvironment: "sandbox",
            countyLabel: countyLabel,
            fireZoneLabel: fireZoneLabel
        )
    }

    @Test("H3 tornado warning notifications stay direct and minimal")
    func h3TornadoWarning() {
        let details = engine.buildNotification(
            for: makeSeries(event: "Tornado Warning", severity: "extreme"),
            with: makePayload(mode: .h3, reason: .new),
            on: makeCandidate()
        )

        #expect(details.title == "Tornado Warning")
        #expect(details.subTitle == "At your location")
        #expect(details.body == "Take shelter now. Tap for details.")
    }

    @Test("UGC updates use the best available local label")
    func ugcUpdateUsesCountyLabel() {
        let details = engine.buildNotification(
            for: makeSeries(event: "Severe Thunderstorm Watch"),
            with: makePayload(mode: .ugc, reason: .update),
            on: makeCandidate(countyLabel: "  Boulder County  ", fireZoneLabel: "Zone 217")
        )

        #expect(details.title == "Severe Thunderstorm Watch Update")
        #expect(details.subTitle == "Updated for Boulder County")
        #expect(details.body == "Stay ready to act quickly. Tap for details.")
    }

    @Test("UGC fire alerts fall back to fire zone labels when needed")
    func ugcFireAlertUsesFireZoneLabel() {
        let details = engine.buildNotification(
            for: makeSeries(event: "Fire Warning"),
            with: makePayload(mode: .ugc, reason: .new),
            on: makeCandidate(fireZoneLabel: "Fire Weather Zone 217")
        )

        #expect(details.title == "Fire Warning")
        #expect(details.subTitle == "For Fire Weather Zone 217")
        #expect(details.body == "Be ready to act quickly if fire conditions worsen. Tap for details.")
    }

    @Test("Cancellation messaging is explicit")
    func cancellationMessage() {
        let details = engine.buildNotification(
            for: makeSeries(event: "Tornado Warning"),
            with: makePayload(mode: .h3, reason: .cancelInError),
            on: makeCandidate()
        )

        #expect(details.title == "Tornado Warning Cancelled")
        #expect(details.subTitle == "Cancelled for your location")
        #expect(details.body == "This alert was cancelled by the issuer. Tap for details.")
    }

    @Test("Generic alerts fall back to trimmed headline or title text")
    func genericAlertFallsBackToHeadline() {
        let details = engine.buildNotification(
            for: makeSeries(
                event: "   ",
                severity: "unknown",
                urgency: "future",
                certainty: "unknown",
                title: "  ",
                headline: "Hazardous Weather Outlook"
            ),
            with: makePayload(mode: .ugc, reason: .new),
            on: makeCandidate()
        )

        #expect(details.title == "Hazardous Weather Outlook")
        #expect(details.subTitle == "For your area")
        #expect(details.body == "Monitor conditions. Tap for details.")
    }
}
