@testable import App
import Foundation
import Testing

@Suite("Presence reconciliation trigger tests")
struct PresenceReconciliationTriggerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let h3Cell: Int64 = 617_700_169_958_293_503

    private var fingerprint: PresenceTargetingFingerprint {
        .init(h3Cell: h3Cell, county: "COC013", forecastZone: "COZ039", fireZone: "COF241")
    }

    private func state(
        fingerprint: PresenceTargetingFingerprint? = nil,
        capturedAt: Date? = nil,
        locationAuth: LocationAuth = .always,
        isActive: Bool = true,
        isSubscribed: Bool = true,
        hasAPNsToken: Bool = true
    ) -> PresenceReconciliationState {
        .init(
            fingerprint: fingerprint ?? self.fingerprint,
            capturedAt: capturedAt ?? now,
            locationAuth: locationAuth,
            isActive: isActive,
            isSubscribed: isSubscribed,
            hasAPNsToken: hasAPNsToken
        )
    }

    @Test("first usable presence triggers reconciliation")
    func firstUsablePresence() {
        let trigger = PresenceReconciliationTrigger.decide(
            previous: nil,
            current: state(),
            now: now
        )

        #expect(trigger?.category == .firstUsablePresence)
    }

    @Test("changed targeting fingerprint while usable triggers movement")
    func movedWhileUsable() {
        let changed = PresenceTargetingFingerprint(
            h3Cell: h3Cell + 1,
            county: "COC013",
            forecastZone: "COZ039",
            fireZone: "COF241"
        )

        let trigger = PresenceReconciliationTrigger.decide(
            previous: state(),
            current: state(fingerprint: changed),
            now: now
        )

        #expect(trigger?.category == .movedWhileUsable)
    }

    @Test("unusable presence becoming usable triggers reconciliation")
    func becameUsable() {
        let previous = state(capturedAt: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold - 1))

        let trigger = PresenceReconciliationTrigger.decide(
            previous: previous,
            current: state(),
            now: now
        )

        #expect(trigger?.category == .becameUsable)
    }

    @Test("unchanged usable heartbeat does not trigger")
    func unchangedUsableHeartbeat() {
        let trigger = PresenceReconciliationTrigger.decide(
            previous: state(capturedAt: now.addingTimeInterval(-60)),
            current: state(),
            now: now
        )

        #expect(trigger == nil)
    }

    @Test("source-independent fingerprint ignores non-targeting state")
    func fingerprintOnlyContainsTargetingFields() {
        let previous = state()
        let current = state(capturedAt: now.addingTimeInterval(-60))

        #expect(previous.fingerprint == current.fingerprint)
    }

    @Test("label-only or targeting-irrelevant changes do not trigger")
    func irrelevantChangesDoNotTrigger() {
        let unchanged = PresenceTargetingFingerprint(
            h3Cell: h3Cell,
            county: "COC013",
            forecastZone: "COZ039",
            fireZone: "COF241"
        )

        let trigger = PresenceReconciliationTrigger.decide(
            previous: state(fingerprint: unchanged),
            current: state(fingerprint: unchanged),
            now: now
        )

        #expect(trigger == nil)
    }

    @Test("unusable to unusable changes do not trigger")
    func unusableToUnusableDoesNotTrigger() {
        let changed = PresenceTargetingFingerprint(
            h3Cell: h3Cell + 1,
            county: "COC013",
            forecastZone: "COZ039",
            fireZone: "COF241"
        )
        let previous = state(isSubscribed: false)

        let trigger = PresenceReconciliationTrigger.decide(
            previous: previous,
            current: state(fingerprint: changed, isSubscribed: false),
            now: now
        )

        #expect(trigger == nil)
    }

    @Test("stale to fresh transition triggers even without movement")
    func staleToFresh() {
        let previous = state(capturedAt: now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold - 1))
        let current = state(capturedAt: now.addingTimeInterval(-60))

        let trigger = PresenceReconciliationTrigger.decide(
            previous: previous,
            current: current,
            now: now
        )

        #expect(trigger?.category == .becameUsable)
    }

    @Test("authorization, subscription, activity, and token state gate usability")
    func deliveryStateGatesUsability() {
        let unavailableStates: [PresenceReconciliationState] = [
            state(locationAuth: .denied),
            state(isActive: false),
            state(isSubscribed: false),
            state(hasAPNsToken: false)
        ]

        for unavailable in unavailableStates {
            let trigger = PresenceReconciliationTrigger.decide(
                previous: nil,
                current: unavailable,
                now: now
            )
            #expect(trigger == nil)
        }
    }
}
