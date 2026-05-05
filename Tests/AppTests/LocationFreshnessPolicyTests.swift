@testable import App
import Foundation
import Testing

@Suite("Location freshness policy tests")
struct LocationFreshnessPolicyTests {
    private let policy = LocationFreshnessPolicy()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func capturedAt(hoursAgo: Double, secondsAgo: Double = 0) -> Date {
        now.addingTimeInterval(-(hoursAgo * 60 * 60) - secondsAgo)
    }

    @Test("When In Use: now is fresh")
    func whenInUseNowFresh() {
        let decision = policy.decide(
            capturedAt: now,
            locationAuth: .whenInUse,
            now: now
        )

        #expect(decision.state == .fresh)
        #expect(decision.age == 0)
    }

    @Test("When In Use: exactly 2 hours is fresh")
    func whenInUseAtTwoHoursFresh() {
        let decision = policy.decide(
            capturedAt: capturedAt(hoursAgo: 2),
            locationAuth: .whenInUse,
            now: now
        )

        #expect(decision.state == .fresh)
    }

    @Test("When In Use: just over 2 hours is degraded")
    func whenInUseJustOverTwoHoursDegraded() {
        let decision = policy.decide(
            capturedAt: capturedAt(hoursAgo: 2, secondsAgo: 1),
            locationAuth: .whenInUse,
            now: now
        )

        #expect(decision.state == .degraded)
    }

    @Test("Always: exactly 6 hours is fresh")
    func alwaysAtSixHoursFresh() {
        let decision = policy.decide(
            capturedAt: capturedAt(hoursAgo: 6),
            locationAuth: .always,
            now: now
        )

        #expect(decision.state == .fresh)
    }

    @Test("Always: just over 6 hours is degraded")
    func alwaysJustOverSixHoursDegraded() {
        let decision = policy.decide(
            capturedAt: capturedAt(hoursAgo: 6, secondsAgo: 1),
            locationAuth: .always,
            now: now
        )

        #expect(decision.state == .degraded)
    }

    @Test("Both modes: exactly 24 hours is degraded")
    func exactlyTwentyFourHoursDegraded() {
        for auth in [LocationAuth.whenInUse, .always] {
            let decision = policy.decide(
                capturedAt: capturedAt(hoursAgo: 24),
                locationAuth: auth,
                now: now
            )
            #expect(decision.state == .degraded)
        }
    }

    @Test("Both modes: just over 24 hours is stale")
    func justOverTwentyFourHoursStale() {
        for auth in [LocationAuth.whenInUse, .always] {
            let decision = policy.decide(
                capturedAt: capturedAt(hoursAgo: 24, secondsAgo: 1),
                locationAuth: auth,
                now: now
            )
            #expect(decision.state == .stale)
        }
    }

    @Test("Non-granted auth modes are conservatively stale")
    func nonGrantedModesAreStale() {
        let nonGrantedModes: [LocationAuth] = [
            .denied,
            .restricted,
            .notDetermined,
            .unknown
        ]

        for auth in nonGrantedModes {
            let decision = policy.decide(
                capturedAt: capturedAt(hoursAgo: 1),
                locationAuth: auth,
                now: now
            )
            #expect(decision.state == .stale)
        }
    }

    @Test("API is capturedAt based and does not accept receivedAt")
    func apiIsCapturedAtOnly() {
        let decision = policy.decide(
            capturedAt: capturedAt(hoursAgo: 1),
            locationAuth: .always,
            now: now
        )

        #expect(decision.state == .fresh)
    }
}
