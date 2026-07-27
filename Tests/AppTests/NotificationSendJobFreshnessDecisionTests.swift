@testable import App
import Foundation
import Testing

@Suite("Notification send job freshness decision")
struct NotificationSendJobFreshnessDecisionTests {
    private let job = NotificationSendJob()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeCandidate(
        auth: LocationAuth,
        capturedAt: Date
    ) -> NotificationCandidate {
        .init(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            apnsToken: "token",
            apnsEnvironment: "sandbox",
            locationAuthRaw: auth.rawValue,
            capturedAt: capturedAt,
            receivedAt: capturedAt.addingTimeInterval(5),
            countyLabel: nil,
            fireZoneLabel: nil
        )
    }

    private func makeSeries(
        state: EventState = .active,
        expires: Date? = nil,
        ends: Date? = nil
    ) -> ArcusSeriesModel {
        .init(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            source: "nws",
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test",
            currentRevisionUrn: "urn:oid:delivery-eligibility",
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: String(repeating: "a", count: 64),
            state: state.rawValue,
            expires: expires,
            ends: ends,
            lastSeenActive: now,
            severity: EventSeverity.severe.rawValue,
            urgency: EventUrgency.immediate.rawValue,
            certainty: EventCertainty.observed.rawValue,
            ugcCodes: []
        )
    }

    @Test("stale candidates are skipped")
    func staleCandidatesAreSkipped() {
        let candidate = makeCandidate(
            auth: .whenInUse,
            capturedAt: now.addingTimeInterval(-(24 * 60 * 60) - 1)
        )

        let disposition = job.deliveryDisposition(for: candidate, evaluatedAt: now)
        if case .skipStale = disposition {
            #expect(Bool(true))
        } else {
            Issue.record("Expected stale candidate to be skipped")
        }
    }

    @Test("stale always-mode candidates are skipped")
    func staleAlwaysCandidatesAreSkipped() {
        let candidate = makeCandidate(
            auth: .always,
            capturedAt: now.addingTimeInterval(-(24 * 60 * 60) - 1)
        )

        let disposition = job.deliveryDisposition(for: candidate, evaluatedAt: now)
        if case .skipStale = disposition {
            #expect(Bool(true))
        } else {
            Issue.record("Expected stale always candidate to be skipped")
        }
    }

    @Test("fresh candidates continue")
    func freshCandidatesContinue() {
        let candidate = makeCandidate(
            auth: .always,
            capturedAt: now.addingTimeInterval(-(60 * 60))
        )

        let disposition = job.deliveryDisposition(for: candidate, evaluatedAt: now)
        if case .deliver = disposition {
            #expect(Bool(true))
        } else {
            Issue.record("Expected fresh candidate to continue")
        }
    }

    @Test("degraded candidates continue")
    func degradedCandidatesContinue() {
        let candidate = makeCandidate(
            auth: .whenInUse,
            capturedAt: now.addingTimeInterval(-(3 * 60 * 60))
        )

        let disposition = job.deliveryDisposition(for: candidate, evaluatedAt: now)
        if case let .deliver(freshness) = disposition {
            #expect(freshness.state == .degraded)
        } else {
            Issue.record("Expected degraded candidate to continue")
        }
    }

    @Test("degraded always-mode candidates continue")
    func degradedAlwaysCandidatesContinue() {
        let candidate = makeCandidate(
            auth: .always,
            capturedAt: now.addingTimeInterval(-(8 * 60 * 60))
        )

        let disposition = job.deliveryDisposition(for: candidate, evaluatedAt: now)
        if case let .deliver(freshness) = disposition {
            #expect(freshness.state == .degraded)
        } else {
            Issue.record("Expected degraded always candidate to continue")
        }
    }

    @Test("new and update notifications stop at inactive or expired series")
    func normalNotificationsStopAtInactiveOrExpiredSeries() {
        let inactiveStates: [EventState] = [.expired, .ended, .cancelled, .cancelled_in_error]

        for state in inactiveStates {
            #expect(
                job.deliveryNoOpReason(
                    for: makeSeries(state: state),
                    reason: .new,
                    evaluatedAt: now
                ) == .inactiveOrExpiredSeries
            )
        }

        #expect(
            job.deliveryNoOpReason(
                for: makeSeries(expires: now),
                reason: .update,
                evaluatedAt: now
            ) == .inactiveOrExpiredSeries
        )
        #expect(
            job.deliveryNoOpReason(
                for: makeSeries(ends: now),
                reason: .update,
                evaluatedAt: now
            ) == .inactiveOrExpiredSeries
        )
        #expect(
            job.deliveryNoOpReason(
                for: makeSeries(expires: now.addingTimeInterval(1), ends: now.addingTimeInterval(1)),
                reason: .new,
                evaluatedAt: now
            ) == nil
        )
    }

    @Test("explicit terminal notifications remain eligible")
    func explicitTerminalNotificationsRemainEligible() {
        let series = makeSeries(state: .cancelled, expires: now, ends: now)

        #expect(job.deliveryNoOpReason(for: series, reason: .cancelInError, evaluatedAt: now) == nil)
        #expect(job.deliveryNoOpReason(for: series, reason: .endedAllClear, evaluatedAt: now) == nil)
    }
}
