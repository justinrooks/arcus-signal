@testable import App
import Foundation
import Testing
import Vapor

@Suite("NWS alert lifecycle", .serialized)
struct NWSAlertLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("expires is a terminal fallback when ends is absent")
    func lifecycleStateUsesExpiresWhenEndsIsAbsent() {
        #expect(
            ArcusEvent.lifecycleState(
                now: now,
                messageType: .alert,
                expiresAt: now,
                endsAt: nil
            ) == .expired
        )
        #expect(
            ArcusEvent.lifecycleState(
                now: now,
                messageType: .alert,
                expiresAt: now.addingTimeInterval(1),
                endsAt: nil
            ) == .active
        )
        #expect(
            ArcusEvent.lifecycleState(
                now: now,
                messageType: .alert,
                expiresAt: now.addingTimeInterval(60),
                endsAt: now
            ) == .expired
        )
    }

    @Test("cleanup expires active series when ends is absent")
    func cleanupExpiresSeriesWithoutEnds() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in

            let series = ArcusSeriesModel(
                source: "nws",
                event: "Tornado Warning",
                sourceURL: "https://api.weather.gov/alerts/test",
                currentRevisionUrn: "urn:oid:expires-without-ends",
                currentRevisionSent: now,
                messageType: NWSAlertMessageType.alert.rawValue,
                contentFingerprint: String(repeating: "a", count: 64),
                state: EventState.active.rawValue,
                expires: now,
                ends: nil,
                lastSeenActive: now,
                severity: EventSeverity.severe.rawValue,
                urgency: EventUrgency.immediate.rawValue,
                certainty: EventCertainty.observed.rawValue,
                ugcCodes: []
            )
            try await series.create(on: app.db)

            _ = try await IngestNWSAlertsJob().startEventCleanup(
                on: app.db,
                asOf: now,
                logger: app.logger
            )

            let stored = try await ArcusSeriesModel.find(series.id, on: app.db)
            #expect(stored?.state == EventState.expired.rawValue)
        }
    }
}
