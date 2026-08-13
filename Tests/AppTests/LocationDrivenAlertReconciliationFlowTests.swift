@testable import App
import ArcusCore
import Fluent
import Foundation
import Queues
import Testing
import Vapor
import VaporTesting
import XCTQueues

@Suite("Location-driven alert reconciliation flow", .serialized)
struct LocationDrivenAlertReconciliationFlowTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true),
            prepare: { app in app.queues.use(.test) },
            test: test
        )
    }

    private func context(for app: Application, queue: String) -> QueueContext {
        QueueContext(
            queueName: QueueName(string: queue),
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    private func uniqueH3Cell() -> Int64 {
        Int64(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
            radix: 16
        )!
    }

    private func seedInstallation(
        id: UUID,
        h3Cell: Int64?,
        county: String?,
        capturedAt: Date = .now,
        auth: LocationAuth = .always,
        subscribed: Bool = true,
        on database: any Database
    ) async throws {
        try await DeviceInstallationModel(
            installationId: id,
            apnsDeviceToken: "token-\(id.uuidString)",
            apnsEnvironment: .sandbox,
            platform: .iOS,
            osVersion: "26.0",
            appVersion: "1.0.0",
            buildNumber: "100",
            locationAuth: auth,
            lastSeenAt: capturedAt,
            isSubscribed: subscribed
        ).create(on: database)
        try await DevicePresenceModel(
            installationId: id,
            capturedAt: capturedAt,
            receivedAt: capturedAt,
            locationAgeSeconds: 0,
            horizontalAccuracyMeters: 10,
            cellScheme: h3Cell == nil ? .ugcOnly : .h3,
            h3Cell: h3Cell,
            h3Resolution: h3Cell == nil ? nil : 8,
            county: county,
            zone: nil,
            fireZone: nil,
            source: .foregroundPrime,
            countyLabel: "Test County",
            fireZoneLabel: nil
        ).create(on: database)
    }

    private func seedAlert(
        mode: NotificationTargetMode,
        h3Cells: [Int64]? = nil,
        ugcCodes: [String] = [],
        state: EventState = .active,
        expires: Date? = Date().addingTimeInterval(3_600),
        ends: Date? = Date().addingTimeInterval(3_600),
        reason: NotificationReason = .new,
        currentOutboxRevision: Bool = true,
        on database: any Database
    ) async throws -> (seriesID: UUID, revisionURN: String) {
        let seriesID = UUID()
        let revisionURN = "urn:oid:\(UUID().uuidString.lowercased())"
        let now = Date()
        try await ArcusSeriesModel(
            id: seriesID,
            source: "nws",
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(seriesID.uuidString.lowercased())",
            currentRevisionUrn: revisionURN,
            currentRevisionSent: now,
            messageType: "alert",
            contentFingerprint: String(repeating: "a", count: 64),
            state: state.rawValue,
            expires: expires,
            ends: ends,
            lastSeenActive: now,
            severity: "severe",
            urgency: "immediate",
            certainty: "observed",
            ugcCodes: ugcCodes
        ).create(on: database)
        try await ArcusEventRevisionModel(
            seriesId: seriesID,
            revisionUrn: revisionURN,
            messageType: "alert",
            sent: now,
            received: now,
            referencedUrns: []
        ).create(on: database)

        let outboxRevision = currentOutboxRevision
            ? revisionURN
            : "urn:oid:\(UUID().uuidString.lowercased())"
        if !currentOutboxRevision {
            try await ArcusEventRevisionModel(
                seriesId: seriesID,
                revisionUrn: outboxRevision,
                messageType: "update",
                sent: now.addingTimeInterval(-60),
                received: now,
                referencedUrns: []
            ).create(on: database)
        }
        try await ArcusNotificationOutboxModel(
            series: seriesID,
            revisionUrn: outboxRevision,
            mode: mode.rawValue,
            reason: reason.rawValue,
            state: "done",
            attempts: 1,
            availableAt: now
        ).create(on: database)

        if let h3Cells {
            try await ArcusGeolocationModel(
                series: seriesID,
                geometry: .point(lon: -104.99, lat: 39.74),
                geometryHash: "geometry-\(seriesID)",
                h3Cells: h3Cells,
                h3Resolution: 8,
                h3Hash: "h3-\(seriesID)"
            ).create(on: database)
        }
        return (seriesID, revisionURN)
    }

    private func reconcile(
        installationID: UUID,
        on app: Application,
        database: any Database
    ) async throws {
        try await ReconcileInstallationAlertsJob().reconcile(
            context(for: app, queue: "test-target"),
            .init(
                intentId: UUID(),
                installationId: installationID,
                triggerCategory: .movedWhileUsable
            ),
            on: database
        )
    }

    private func deliver(
        _ payload: NotificationSendJobPayload,
        sender: FlowRecordingNotificationSender,
        on app: Application
    ) async throws {
        try await NotificationSendJob(sender: sender).dequeue(
            context(for: app, queue: "test-send"),
            payload
        )
    }

    private func claimAfterBarrier(
        _ barrier: TwoPartyBarrier,
        installationID: UUID,
        seriesID: UUID,
        revisionURN: String,
        on database: any Database
    ) async throws -> LedgerClaimResult {
        await barrier.arriveAndWait()
        return try await NotificationDeliveryStore().claim(
            installationID: installationID,
            seriesID: seriesID,
            revisionUrn: revisionURN,
            mode: .h3,
            reason: .new,
            freshnessState: .fresh,
            on: database
        )
    }

    @Test("entry sends once, re-entry does not resend, and a new revision is independent")
    func entryReentryAndNewRevision() async throws {
        try await withApp { app in
            let installationID = UUID()
            let insideCell = uniqueH3Cell()
            let outsideCell = insideCell + 1
            let startedAt = Date().addingTimeInterval(-30)
            let sender = FlowRecordingNotificationSender()

            try await submit(
                snapshot(
                    for: installationID,
                    capturedAt: startedAt,
                    cellScheme: .h3,
                    h3Cell: outsideCell
                ),
                to: app
            )
            let alert = try await seedAlert(mode: .h3, h3Cells: [insideCell], on: app.db)

            let initialReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .first { $0.installationId == installationID }
            )
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), initialReconcile, on: app.db
            )
            #expect(app.queues.test.all(NotificationSendJob.self)
                .contains { $0.installationId == installationID } == false)

            try await submit(
                snapshot(
                    for: installationID,
                    capturedAt: startedAt.addingTimeInterval(1),
                    cellScheme: .h3,
                    h3Cell: insideCell
                ),
                to: app
            )
            let entryReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .last { $0.installationId == installationID }
            )
            #expect(entryReconcile.intentId != initialReconcile.intentId)
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), entryReconcile, on: app.db
            )
            let firstPayload = try #require(
                app.queues.test.all(NotificationSendJob.self)
                    .last { $0.installationId == installationID }
            )
            try await deliver(firstPayload, sender: sender, on: app)

            let sendCountAfterEntry = app.queues.test.all(NotificationSendJob.self)
                .filter { $0.installationId == installationID }.count
            try await submit(
                snapshot(
                    for: installationID,
                    capturedAt: startedAt.addingTimeInterval(2),
                    cellScheme: .h3,
                    h3Cell: outsideCell
                ),
                to: app
            )
            let leaveReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .last { $0.installationId == installationID }
            )
            #expect(leaveReconcile.intentId != entryReconcile.intentId)
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), leaveReconcile, on: app.db
            )
            #expect(app.queues.test.all(NotificationSendJob.self)
                .filter { $0.installationId == installationID }.count == sendCountAfterEntry)

            try await submit(
                snapshot(
                    for: installationID,
                    capturedAt: startedAt.addingTimeInterval(3),
                    cellScheme: .h3,
                    h3Cell: insideCell
                ),
                to: app
            )
            let reentryReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .last { $0.installationId == installationID }
            )
            #expect(reentryReconcile.intentId != leaveReconcile.intentId)
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), reentryReconcile, on: app.db
            )
            let reentryPayloads = app.queues.test.all(NotificationSendJob.self)
                .filter { $0.installationId == installationID }
            #expect(reentryPayloads.count == sendCountAfterEntry + 1)
            let duplicatePayload = try #require(reentryPayloads.last)
            try await deliver(duplicatePayload, sender: sender, on: app)
            #expect(await sender.sendCount == 1)

            let secondRevision = "urn:oid:\(UUID().uuidString.lowercased())"
            let series = try #require(try await ArcusSeriesModel.find(alert.seriesID, on: app.db))
            series.currentRevisionUrn = secondRevision
            series.currentRevisionSent = .now
            try await series.update(on: app.db)
            try await ArcusEventRevisionModel(
                seriesId: alert.seriesID,
                revisionUrn: secondRevision,
                messageType: "update",
                sent: .now,
                received: .now,
                referencedUrns: [alert.revisionURN]
            ).create(on: app.db)
            try await ArcusNotificationOutboxModel(
                series: alert.seriesID,
                revisionUrn: secondRevision,
                mode: NotificationTargetMode.h3.rawValue,
                reason: NotificationReason.update.rawValue,
                state: "done",
                attempts: 1,
                availableAt: .now
            ).create(on: app.db)
            let revisionPayload = NotificationSendJobPayload(
                seriesId: alert.seriesID,
                revisionUrn: secondRevision,
                mode: .h3,
                reason: .update
            )
            try await deliver(revisionPayload, sender: sender, on: app)

            let claims = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == alert.seriesID)
                .all()
            #expect(claims.count == 2)
            #expect(await sender.sendCount == 2)
        }
    }

    @Test("first usable and stale-to-usable presence discover an existing alert; heartbeat does not")
    func authoritativePresenceTransitions() async throws {
        try await withApp { app in
            let county = "county-\(UUID().uuidString.lowercased())"
            _ = try await seedAlert(mode: .ugc, ugcCodes: [county], on: app.db)
            let sender = FlowRecordingNotificationSender()

            let firstID = UUID()
            try await submit(snapshot(for: firstID, county: county), to: app)
            let firstIntent = try #require(try await intent(for: firstID, on: app.db))
            #expect(firstIntent.triggerCategory == .firstUsablePresence)
            let firstReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self).first { $0.installationId == firstID }
            )
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), firstReconcile, on: app.db
            )
            let firstSend = try #require(
                app.queues.test.all(NotificationSendJob.self).first { $0.installationId == firstID }
            )
            try await deliver(firstSend, sender: sender, on: app)

            let staleID = UUID()
            let staleDate = Date().addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold - 60)
            try await submit(snapshot(for: staleID, county: county, capturedAt: staleDate), to: app)
            #expect(try await intent(for: staleID, on: app.db) == nil)
            try await submit(snapshot(for: staleID, county: county), to: app)
            let recoveredIntent = try #require(try await intent(for: staleID, on: app.db))
            #expect(recoveredIntent.triggerCategory == .becameUsable)
            let recoveredReconcile = try #require(
                app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .first { $0.installationId == staleID }
            )
            try await ReconcileInstallationAlertsJob().reconcile(
                context(for: app, queue: "test-target"), recoveredReconcile, on: app.db
            )
            let recoveredSend = try #require(
                app.queues.test.all(NotificationSendJob.self).first { $0.installationId == staleID }
            )
            try await deliver(recoveredSend, sender: sender, on: app)

            let intentCount = try await PresenceReconciliationOutboxModel.query(on: app.db)
                .filter(\.$installation.$id == firstID)
                .count()
            let reconcileCount = app.queues.test.all(ReconcileInstallationAlertsJob.self)
                .filter { $0.installationId == firstID }.count
            try await submit(
                snapshot(for: firstID, county: county, capturedAt: Date().addingTimeInterval(1), source: .backgroundLocationChange),
                to: app
            )
            #expect(try await PresenceReconciliationOutboxModel.query(on: app.db)
                .filter(\.$installation.$id == firstID).count() == intentCount)
            #expect(app.queues.test.all(ReconcileInstallationAlertsJob.self)
                .filter { $0.installationId == firstID }.count == reconcileCount)
            #expect(await sender.sendCount == 2)
        }
    }

    @Test("H3 and UGC fallback deliver while inactive and stale revisions are excluded")
    func targetingAndLifecycleMatrix() async throws {
        try await withApp { app in
            let installationID = UUID()
            let h3Cell = uniqueH3Cell()
            let county = "county-\(UUID().uuidString.lowercased())"
            try await seedInstallation(id: installationID, h3Cell: h3Cell, county: county, on: app.db)
            let h3 = try await seedAlert(mode: .h3, h3Cells: [h3Cell], on: app.db)
            let ugc = try await seedAlert(mode: .ugc, ugcCodes: [county], on: app.db)
            let expired = try await seedAlert(mode: .ugc, ugcCodes: [county], state: .expired, on: app.db)
            let ended = try await seedAlert(mode: .ugc, ugcCodes: [county], state: .ended, on: app.db)
            let cancelled = try await seedAlert(mode: .ugc, ugcCodes: [county], state: .cancelled, on: app.db)
            let timeExpired = try await seedAlert(mode: .ugc, ugcCodes: [county], expires: .now, on: app.db)
            let timeEnded = try await seedAlert(mode: .ugc, ugcCodes: [county], ends: .now, on: app.db)
            let staleRevision = try await seedAlert(
                mode: .ugc,
                ugcCodes: [county],
                currentOutboxRevision: false,
                on: app.db
            )

            try await reconcile(installationID: installationID, on: app, database: app.db)
            let payloads = app.queues.test.all(NotificationSendJob.self)
            #expect(Set(payloads.map(\.seriesId)) == [h3.seriesID, ugc.seriesID])
            let excludedSeries = Set([
                expired.seriesID,
                ended.seriesID,
                cancelled.seriesID,
                timeExpired.seriesID,
                timeEnded.seriesID,
                staleRevision.seriesID
            ])
            #expect(Set(payloads.map(\.seriesId)).isDisjoint(with: excludedSeries))

            let sender = FlowRecordingNotificationSender()
            for payload in payloads {
                try await deliver(payload, sender: sender, on: app)
            }
            #expect(await sender.sendCount == 2)
        }
    }

    @Test("alert and location discovery race converges on one ledger claim")
    func concurrentDiscoveryConvergesOnOneClaim() async throws {
        try await withApp { app in
            let installationID = UUID()
            let otherInstallationID = UUID()
            let h3Cell = uniqueH3Cell()
            try await seedInstallation(id: installationID, h3Cell: h3Cell, county: nil, on: app.db)
            try await seedInstallation(id: otherInstallationID, h3Cell: h3Cell, county: nil, on: app.db)
            let alert = try await seedAlert(mode: .h3, h3Cells: [h3Cell], on: app.db)
            let sender = FlowGatedNotificationSender()
            let job = NotificationSendJob(sender: sender)

            let cutoff = Date().addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)
            let constrainedCandidates = try await NotificationCandidateStore().loadH3Candidates(
                cells: [h3Cell],
                capturedAtOrAfter: cutoff,
                installationId: installationID,
                on: app.db
            )
            let unconstrainedCandidates = try await NotificationCandidateStore().loadH3Candidates(
                cells: [h3Cell],
                capturedAtOrAfter: cutoff,
                on: app.db
            )
            #expect(constrainedCandidates.map(\.id) == [installationID])
            #expect(Set(unconstrainedCandidates.map(\.id)) == [installationID, otherInstallationID])

            let locationDriven = Task {
                try await job.dequeue(
                    context(for: app, queue: "location-driven"),
                    .init(
                        seriesId: alert.seriesID,
                        revisionUrn: alert.revisionURN,
                        mode: .h3,
                        reason: .new,
                        installationId: installationID
                    )
                )
            }
            do {
                try await sender.waitForFirstSend()
            } catch {
                await sender.releaseFirstSend()
                locationDriven.cancel()
                _ = await locationDriven.result
                throw error
            }

            let alertDriven = Task {
                try await job.dequeue(
                    context(for: app, queue: "alert-driven"),
                    .init(
                        seriesId: alert.seriesID,
                        revisionUrn: alert.revisionURN,
                        mode: .h3,
                        reason: .new
                    )
                )
            }
            do {
                try await sender.waitForSendCount(2)
                await sender.releaseFirstSend()
                try await alertDriven.value
                try await locationDriven.value
            } catch {
                await sender.releaseFirstSend()
                alertDriven.cancel()
                locationDriven.cancel()
                _ = await alertDriven.result
                _ = await locationDriven.result
                throw error
            }

            let targetClaims = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == alert.seriesID)
                .filter(\.$revisionUrn == alert.revisionURN)
                .count()
            let otherClaims = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == otherInstallationID)
                .filter(\.$series.$id == alert.seriesID)
                .filter(\.$revisionUrn == alert.revisionURN)
                .count()
            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$series.$id == alert.seriesID)
                .filter(\.$revisionUrn == alert.revisionURN)
                .all()
            #expect(targetClaims == 1)
            #expect(otherClaims == 1)
            #expect(attempts.contains { $0.candidateCount == 1 })
            #expect(attempts.contains { $0.candidateCount == 2 })
            #expect(await sender.sendCount == 2)

            let collisionRevision = "urn:oid:claim-race-\(UUID().uuidString.lowercased())"
            let barrier = TwoPartyBarrier()
            async let firstClaim = claimAfterBarrier(
                barrier,
                installationID: installationID,
                seriesID: alert.seriesID,
                revisionURN: collisionRevision,
                on: app.db
            )
            async let secondClaim = claimAfterBarrier(
                barrier,
                installationID: installationID,
                seriesID: alert.seriesID,
                revisionURN: collisionRevision,
                on: app.db
            )
            let (firstResult, secondResult) = try await (firstClaim, secondClaim)
            let claimResults = [firstResult, secondResult]
            #expect(claimResults.filter(\.inserted).count == 1)
            #expect(try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == alert.seriesID)
                .filter(\.$revisionUrn == collisionRevision)
                .count() == 1)
        }
    }

    @Test("race gate reports a missing production send without hanging")
    func raceGateReportsMissingSend() async throws {
        try await withApp { app in
            let installationID = UUID()
            let h3Cell = uniqueH3Cell()
            try await seedInstallation(id: installationID, h3Cell: h3Cell, county: nil, on: app.db)
            let alert = try await seedAlert(
                mode: .h3,
                h3Cells: [h3Cell],
                state: .expired,
                on: app.db
            )
            let sender = FlowGatedNotificationSender()
            let dequeue = Task {
                try await NotificationSendJob(sender: sender).dequeue(
                    context(for: app, queue: "missing-send"),
                    .init(
                        seriesId: alert.seriesID,
                        revisionUrn: alert.revisionURN,
                        mode: .h3,
                        reason: .new,
                        installationId: installationID
                    )
                )
            }

            do {
                try await sender.waitForFirstSend(timeout: .milliseconds(50))
                Issue.record("Expected the inactive series to produce no send.")
            } catch let error as FlowGateTimeoutError {
                #expect(error.expectedSendCount == 1)
                #expect(error.actualSendCount == 0)
            }

            await sender.releaseFirstSend()
            try await dequeue.value
        }
    }

    @Test("duplicate drain and reconciliation retry remain idempotent")
    func duplicateDrainAndRetry() async throws {
        try await withApp { app in
            let installationID = UUID()
            let county = "county-\(UUID().uuidString.lowercased())"
            try await seedInstallation(id: installationID, h3Cell: nil, county: county, on: app.db)
            _ = try await seedAlert(mode: .ugc, ugcCodes: [county], on: app.db)
            let dispatcher = GatedDuplicateReconciliationDispatcher()
            app.presenceReconciliationHandoff = PresenceReconciliationHandoff(
                dispatcher: dispatcher
            )
            let capture = FlowPayloadCapture()
            try await withRollbackTransaction(on: app) { database in
                try await PresenceReconciliationOutboxModel.query(on: database)
                    .filter(\.$stateRaw == PresenceReconciliationOutboxState.ready.rawValue)
                    .set(\.$stateRaw, to: PresenceReconciliationOutboxState.done.rawValue)
                    .update()
                let insert = try await PresenceReconciliationOutboxStore().insert(
                    installationID: installationID,
                    presenceCapturedAt: .now,
                    triggerCategory: .movedWhileUsable,
                    targetingFingerprint: "fingerprint-\(UUID().uuidString)",
                    availableAt: .distantPast,
                    on: database
                )
                let scheduled = DispatchPresenceReconciliationScheduledJob()
                async let firstDrain: Void = scheduled.dispatchReady(
                    context: context(for: app, queue: "scheduled"),
                    on: database
                )
                await dispatcher.waitForFirstDispatch()
                try await scheduled.dispatchReady(
                    context: context(for: app, queue: "scheduled"),
                    on: database
                )
                try await firstDrain
                let reconcilePayloads = app.queues.test.all(ReconcileInstallationAlertsJob.self)
                    .filter { $0.intentId == insert.id }
                #expect(reconcilePayloads.count == 2)

                let job = ReconcileInstallationAlertsJob()
                for payload in reconcilePayloads {
                    try await job.reconcile(
                        context(for: app, queue: "test-target"),
                        payload,
                        on: database
                    )
                }
                let sendPayloads = app.queues.test.all(NotificationSendJob.self)
                    .filter { $0.installationId == installationID }
                #expect(sendPayloads.count == 2)
                await capture.store(sendPayloads)
            }

            let sender = FlowRecordingNotificationSender()
            for sendPayload in await capture.payloads {
                try await deliver(sendPayload, sender: sender, on: app)
            }
            #expect(await sender.sendCount == 1)
        }
    }

    private func snapshot(
        for installationID: UUID,
        county: String? = nil,
        capturedAt: Date = .now,
        source: LocationUploadSource = .foregroundPrime,
        cellScheme: CellScheme = .ugcOnly,
        h3Cell: Int64? = nil
    ) -> LocationSnapshotPushPayload {
        LocationSnapshotPushPayload(
            capturedAt: capturedAt,
            locationAgeSeconds: 0,
            horizontalAccuracyMeters: 10,
            cellScheme: cellScheme.rawValue,
            h3Cell: h3Cell,
            h3Resolution: h3Cell == nil ? nil : 8,
            county: county,
            zone: nil,
            fireZone: nil,
            apnsDeviceToken: "token-\(installationID.uuidString)",
            installationId: installationID.uuidString,
            source: source.rawValue,
            auth: LocationAuth.always.rawValue,
            appVersion: "1.0.0",
            buildNumber: "100",
            platform: Platform.iOS.rawValue,
            osVersion: "26.0",
            apnsEnvironment: APNsEnvironment.sandbox.rawValue,
            countyLabel: "Test County",
            fireZoneLabel: nil,
            isSubscribed: true
        )
    }

    private func submit(_ payload: LocationSnapshotPushPayload, to app: Application) async throws {
        try await app.testing().test(
            .POST,
            "api/v1/devices/location-snapshots",
            beforeRequest: { request in
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                request.headers.contentType = .json
                request.body = .init(data: try encoder.encode(payload))
            },
            afterResponse: { response async in #expect(response.status == .ok) }
        )
    }

    private func intent(
        for installationID: UUID,
        on database: any Database
    ) async throws -> PresenceReconciliationOutboxModel? {
        try await PresenceReconciliationOutboxModel.query(on: database)
            .filter(\.$installation.$id == installationID)
            .first()
    }
}

private actor FlowRecordingNotificationSender: NotificationSender {
    private(set) var sendCount = 0

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        sendCount += 1
    }
}

private actor FlowGatedNotificationSender: NotificationSender {
    private(set) var sendCount = 0
    private var firstSendRelease: CheckedContinuation<Void, Never>?

    func waitForFirstSend(timeout: Duration = .seconds(2)) async throws {
        try await waitForSendCount(1, timeout: timeout)
    }

    func waitForSendCount(
        _ expectedCount: Int,
        timeout: Duration = .seconds(2)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while sendCount < expectedCount {
            guard clock.now < deadline else {
                throw FlowGateTimeoutError(
                    expectedSendCount: expectedCount,
                    actualSendCount: sendCount
                )
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func releaseFirstSend() {
        firstSendRelease?.resume()
        firstSendRelease = nil
    }

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        sendCount += 1

        if sendCount == 1 {
            await withCheckedContinuation { continuation in
                firstSendRelease = continuation
            }
        }
    }
}

private struct FlowGateTimeoutError: Error {
    let expectedSendCount: Int
    let actualSendCount: Int
}

private actor TwoPartyBarrier {
    private var arrivalCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrivalCount += 1
        if arrivalCount == 2 {
            let pending = waiters
            waiters.removeAll()
            pending.forEach { $0.resume() }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

private actor FlowPayloadCapture {
    private(set) var payloads: [NotificationSendJobPayload] = []

    func store(_ payloads: [NotificationSendJobPayload]) {
        self.payloads = payloads
    }
}

private actor GatedDuplicateReconciliationDispatcher: ReconcileInstallationAlertsJobDispatching {
    private var dispatchCount = 0
    private var firstDispatchWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstDispatchRelease: CheckedContinuation<Void, Never>?

    func waitForFirstDispatch() async {
        guard dispatchCount == 0 else { return }

        await withCheckedContinuation { continuation in
            firstDispatchWaiters.append(continuation)
        }
    }

    func dispatch(
        _ payload: ReconcileInstallationAlertsJobPayload,
        on application: Application
    ) async throws {
        try await application.queues
            .queue(ArcusQueueLane.target.queueName)
            .dispatch(
                ReconcileInstallationAlertsJob.self,
                payload,
                maxRetryCount: ReconcileInstallationAlertsJob.maximumRetryCount
            )

        dispatchCount += 1
        if dispatchCount == 1 {
            let waiters = firstDispatchWaiters
            firstDispatchWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstDispatchRelease = continuation
            }
        } else if dispatchCount == 2 {
            firstDispatchRelease?.resume()
            firstDispatchRelease = nil
        }
    }
}
