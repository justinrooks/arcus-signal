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
}
