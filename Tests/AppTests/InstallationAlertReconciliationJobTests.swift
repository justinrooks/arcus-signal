@testable import App
import Fluent
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues

@Suite("Installation alert reconciliation jobs", .serialized)
struct InstallationAlertReconciliationJobTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            app.queues.use(.test)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func context(for app: Application) -> QueueContext {
        QueueContext(
            queueName: QueueName(string: "scheduled"),
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    private func seedInstallation(
        id: UUID,
        county: String,
        isSubscribed: Bool = true,
        on database: any Database
    ) async throws {
        try await DeviceInstallationModel(
            installationId: id,
            apnsDeviceToken: "test-token",
            apnsEnvironment: .sandbox,
            platform: .iOS,
            osVersion: "26.0",
            appVersion: "1.0.0",
            buildNumber: "100",
            locationAuth: .always,
            lastSeenAt: .now,
            isSubscribed: isSubscribed
        ).create(on: database)

        try await DevicePresenceModel(
            installationId: id,
            capturedAt: .now,
            receivedAt: .now,
            locationAgeSeconds: 0,
            horizontalAccuracyMeters: 10,
            cellScheme: .ugcOnly,
            h3Cell: nil,
            h3Resolution: nil,
            county: county,
            zone: nil,
            fireZone: nil,
            source: .foregroundPrime,
            countyLabel: "Test County",
            fireZoneLabel: nil
        ).create(on: database)
    }

    private func seedActiveAlert(
        county: String,
        on database: any Database
    ) async throws -> (seriesId: UUID, revisionUrn: String) {
        let now = Date()
        let seriesId = UUID()
        let revisionUrn = "urn:oid:\(UUID().uuidString.lowercased())"
        try await ArcusSeriesModel(
            id: seriesId,
            source: "nws",
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(seriesId.uuidString.lowercased())",
            currentRevisionUrn: revisionUrn,
            currentRevisionSent: now,
            messageType: "alert",
            contentFingerprint: String(repeating: "a", count: 64),
            state: EventState.active.rawValue,
            expires: now.addingTimeInterval(600),
            ends: now.addingTimeInterval(600),
            lastSeenActive: now,
            severity: "severe",
            urgency: "immediate",
            certainty: "observed",
            ugcCodes: [county]
        ).create(on: database)
        try await ArcusEventRevisionModel(
            seriesId: seriesId,
            revisionUrn: revisionUrn,
            messageType: "alert",
            sent: now,
            received: now,
            referencedUrns: []
        ).create(on: database)
        try await ArcusNotificationOutboxModel(
            series: seriesId,
            revisionUrn: revisionUrn,
            mode: NotificationTargetMode.ugc.rawValue,
            reason: NotificationReason.new.rawValue,
            state: "done",
            attempts: 1,
            availableAt: now
        ).create(on: database)
        return (seriesId, revisionUrn)
    }

    @Test("scheduled drain hands ready intents to the target lane with bounded job retries")
    func scheduledDrainDispatchesReadyIntents() async throws {
        try await withApp { app in
            let capture = ReconciliationDispatchCapture()
            app.queues.add(capture)

            try await withRollbackTransaction(on: app) { database in
                try await PresenceReconciliationOutboxModel.query(on: database)
                    .filter(\.$stateRaw == PresenceReconciliationOutboxState.ready.rawValue)
                    .set(\.$stateRaw, to: PresenceReconciliationOutboxState.done.rawValue)
                    .update()
                let installationId = UUID()
                try await seedInstallation(id: installationId, county: "COC031", on: database)
                let inserted = try await PresenceReconciliationOutboxStore().insert(
                    installationID: installationId,
                    presenceCapturedAt: .now,
                    triggerCategory: .firstUsablePresence,
                    targetingFingerprint: "opaque-fingerprint",
                    availableAt: .distantPast,
                    on: database
                )
                let intentId = try #require(inserted.id)

                let scheduledJob = DispatchPresenceReconciliationScheduledJob()
                try await scheduledJob.dispatchReady(context: context(for: app), on: database)
                try await scheduledJob.dispatchReady(context: context(for: app), on: database)

                let payloads = app.queues.test.all(ReconcileInstallationAlertsJob.self)
                #expect(payloads.count == 1)
                #expect(payloads.first?.intentId == intentId)
                #expect(payloads.first?.installationId == installationId)
                #expect(payloads.first?.triggerCategory == .firstUsablePresence)

                let row = try #require(
                    try await PresenceReconciliationOutboxModel.find(intentId, on: database)
                )
                #expect(row.state == .done)
                #expect(row.attemptCount == 1)

                let event = try #require(
                    await capture.firstDispatch(jobName: ReconcileInstallationAlertsJob.name)
                )
                #expect(event.queueName == ArcusQueueLane.target.rawValue)
                #expect(event.maxRetryCount == ReconcileInstallationAlertsJob.maximumRetryCount)
            }
        }
    }

    @Test("reconciliation dispatches installation-constrained send work on the send lane")
    func reconciliationDispatchesConstrainedSendWork() async throws {
        try await withApp { app in
            let capture = ReconciliationDispatchCapture()
            app.queues.add(capture)

            try await withRollbackTransaction(on: app) { database in
                let installationId = UUID()
                let county = "county-\(UUID().uuidString.lowercased())"
                try await seedInstallation(id: installationId, county: county, on: database)
                let alert = try await seedActiveAlert(county: county, on: database)

                try await ReconcileInstallationAlertsJob().reconcile(
                    context(for: app),
                    .init(
                        intentId: UUID(),
                        installationId: installationId,
                        triggerCategory: .movedWhileUsable
                    ),
                    on: database
                )

                let payload = try #require(app.queues.test.first(NotificationSendJob.self))
                #expect(payload.seriesId == alert.seriesId)
                #expect(payload.revisionUrn == alert.revisionUrn)
                #expect(payload.mode == .ugc)
                #expect(payload.reason == .new)
                #expect(payload.installationId == installationId)

                let event = try #require(
                    await capture.firstDispatch(jobName: NotificationSendJob.name)
                )
                #expect(event.queueName == ArcusQueueLane.send.rawValue)
            }
        }
    }

    @Test("delayed reconciliation uses latest presence and succeeds with zero current matches")
    func delayedReconciliationUsesLatestPresence() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationId = UUID()
                let originalCounty = "county-\(UUID().uuidString.lowercased())"
                try await seedInstallation(id: installationId, county: originalCounty, on: database)
                _ = try await seedActiveAlert(county: originalCounty, on: database)

                let presence = try #require(
                    try await DevicePresenceModel.find(installationId, on: database)
                )
                presence.county = "county-\(UUID().uuidString.lowercased())"
                presence.capturedAt = .now
                try await presence.update(on: database)

                try await ReconcileInstallationAlertsJob().reconcile(
                    context(for: app),
                    .init(
                        intentId: UUID(),
                        installationId: installationId,
                        triggerCategory: .movedWhileUsable
                    ),
                    on: database
                )

                #expect(app.queues.test.contains(NotificationSendJob.self) == false)
            }
        }
    }

    @Test("unusable latest installation stops before constrained send dispatch")
    func unusableInstallationStopsReconciliation() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let installationId = UUID()
                let county = "county-\(UUID().uuidString.lowercased())"
                try await seedInstallation(
                    id: installationId,
                    county: county,
                    isSubscribed: false,
                    on: database
                )
                _ = try await seedActiveAlert(county: county, on: database)

                try await ReconcileInstallationAlertsJob().reconcile(
                    context(for: app),
                    .init(
                        intentId: UUID(),
                        installationId: installationId,
                        triggerCategory: .becameUsable
                    ),
                    on: database
                )

                #expect(app.queues.test.contains(NotificationSendJob.self) == false)
            }
        }
    }

    @Test("reconciliation retry delays are bounded")
    func retryDelaysAreBounded() {
        let job = ReconcileInstallationAlertsJob()
        #expect(job.nextRetryIn(attempt: 1) == 15)
        #expect(job.nextRetryIn(attempt: 2) == 60)
        #expect(job.nextRetryIn(attempt: 3) == 300)
        #expect(job.nextRetryIn(attempt: 99) == 300)
    }
}

private actor ReconciliationDispatchCapture: AsyncJobEventDelegate {
    private var dispatches: [JobEventData] = []

    func dispatched(job: JobEventData) async throws {
        dispatches.append(job)
    }

    func firstDispatch(jobName: String) -> JobEventData? {
        dispatches.first { $0.jobName == jobName }
    }
}
