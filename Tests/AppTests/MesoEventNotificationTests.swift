@testable import App
import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues

@Suite("Event-first meso notifications", .serialized)
struct MesoEventNotificationTests {
    @Test("only the explicit true environment value enables the rollout", arguments: ["absent", "false", "TRUE", "true"])
    func configuredGate(value: String) async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: false)) { app in
            // Use the startup configuration function without mutating the shared
            // process environment while other suites may configure applications.
            configureMesoNotifications(on: app, value: value == "absent" ? nil : value)
            #expect(app.mesoNotificationsEnabled == (value == "true"))
        }
    }

    private func product(now: Date = .now, summary: String = "Storms developing") throws -> MesoscaleDiscussionPayload {
        .init(number: 9875, title: "Mesoscale Discussion 9875",
            sourceURL: try #require(URL(string: "https://www.spc.noaa.gov/products/md/md9875.html")),
            issued: now, validStart: now.addingTimeInterval(-60), validEnd: now.addingTimeInterval(3600),
            areasAffected: "Test area", summary: summary, concerning: nil, watchProbability: 30,
            watchProbabilityText: "30", threats: nil,
            coordinates: [.init(latitude: 35, longitude: -98), .init(latitude: 36, longitude: -98),
                          .init(latitude: 36, longitude: -97), .init(latitude: 35, longitude: -98)])
    }

    private func context(_ app: Application) -> QueueContext {
        .init(queueName: ArcusQueueLane.send.queueName, configuration: app.queues.configuration,
              application: app, logger: app.logger, on: app.eventLoopGroup.any())
    }

    private func retryContext(_ app: Application, payload: MesoNotificationSendPayload) throws -> QueueContext {
        let id = JobIdentifier(string: UUID().uuidString)
        app.queues.test.jobs[id] = JobData(payload: Array(try JSONEncoder().encode(payload)),
            maxRetryCount: MesoNotificationSendJob.maximumRetryCount, jobName: MesoNotificationSendJob.name,
            delayUntil: nil, queuedAt: .now, attempts: 1)
        var logger = app.logger
        logger[metadataKey: "job_id"] = .string(id.string)
        return .init(queueName: ArcusQueueLane.send.queueName, configuration: app.queues.configuration,
                     application: app, logger: logger, on: app.eventLoopGroup.any())
    }

    private func fixture(_ body: (Application, MesoscaleDiscussionPayload) async throws -> Void) async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            app.queues.use(.test)
            // Each suite run uses an isolated database; cleanup also supports reuse.
            let discussion = try product()
            do {
                try await body(app, discussion)
            } catch {
                try await cleanup(app, productID: discussion.productID)
                throw error
            }
            try await cleanup(app, productID: discussion.productID)
        }
    }

    private func cleanup(_ app: Application, productID: String) async throws {
        try await NotificationDebugModel.query(on: app.db).filter(\.$subjectID == productID).delete()
        try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == "meso-event-test-" + productID).delete()
        try await NotificationSendAttemptModel.query(on: app.db).filter(\.$subjectID == productID).delete()
        try await DeviceInstallationModel.query(on: app.db).filter(\.$apnsDeviceToken ~~ "meso-event-test-").delete()
        try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == productID).delete()
        try await SPCMesoModel.query(on: app.db).filter(\.$productKey == productID).delete()
    }

    @discardableResult
    private func installation(_ app: Application, cell: Int64?, preference: Bool? = true,
                              subscribed: Bool = true, active: Bool = true, capturedAt: Date = .now,
                              auth: LocationAuth = .always, resolution: Int = 8) async throws -> UUID {
        let id = UUID()
        try await DeviceInstallationModel(installationId: id, apnsDeviceToken: "meso-event-test-\(id)",
            apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26", appVersion: "1", buildNumber: "1",
            locationAuth: auth, isActive: active, lastSeenAt: .now, isSubscribed: subscribed,
            mesoNotificationsEnabled: preference).create(on: app.db)
        try await DevicePresenceModel(installationId: id, capturedAt: capturedAt, locationAgeSeconds: 0,
            horizontalAccuracyMeters: 10, cellScheme: cell == nil ? .ugcOnly : .h3, h3Cell: cell,
            h3Resolution: resolution, county: "OK001", zone: nil, fireZone: nil, source: .foregroundPrime,
            countyLabel: "Test County", fireZoneLabel: nil).create(on: app.db)
        return id
    }

    private func persist(_ app: Application, _ discussion: MesoscaleDiscussionPayload, at date: Date = .now) async throws -> Int64 {
        _ = try await SPCMesoIngestPersistence().persist([discussion], on: app.db, seenAt: date,
                                                       enqueueNotifications: app.mesoNotificationsEnabled)
        let meso = try #require(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == discussion.productID).first())
        let geometry = try #require(try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == meso.requireID()).first())
        return try #require(geometry.h3Cells.first)
    }

    private func reconcile(_ app: Application, installationID: UUID) async throws -> [MesoNotificationSendPayload] {
        let before = app.queues.test.all(MesoNotificationSendJob.self).count
        try await ReconcileInstallationAlertsJob().reconcile(context(app), .init(
            intentId: UUID(), installationId: installationID, triggerCategory: .movedWhileUsable
        ), on: app.db)
        return Array(app.queues.test.all(MesoNotificationSendJob.self).dropFirst(before))
    }

    private func move(_ app: Application, installationID: UUID, cell: Int64) async throws {
        let presence = try #require(try await DevicePresenceModel.find(installationID, on: app.db))
        presence.h3Cell = cell
        try await presence.update(on: app.db)
    }

    @Test("event-first and presence-first converge across repeated covered moves", arguments: [true, false])
    func presenceDiscovery(eventFirst: Bool) async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: eventFirst ? cell : cell + 1000)
            let sender = MesoEventRecordingSender()
            let job = MesoNotificationSendJob(sender: sender)
            let event = MesoNotificationSendPayload(issueYear: discussion.issueYear, number: discussion.number)
            if eventFirst { try await job.dequeue(context(app), event) }
            else { #expect(try await reconcile(app, installationID: id).isEmpty) }
            try await move(app, installationID: id, cell: cell)
            let other = try await installation(app, cell: cell)
            for _ in 0..<2 {
                let payload = try #require(try await reconcile(app, installationID: id).first)
                #expect(payload.installationID == id)
                try await job.dequeue(context(app), payload)
            }
            // A second covered cell represents a meaningful move within the MD.
            let meso = try #require(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == discussion.productID).first())
            let geometry = try #require(try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == meso.requireID()).first())
            try await move(app, installationID: id, cell: try #require(geometry.h3Cells.first { $0 != cell }))
            for payload in try await reconcile(app, installationID: id) { try await job.dequeue(context(app), payload) }
            #expect(await sender.tokens == ["meso-event-test-\(id)"])
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == other).count() == 0)
            if !eventFirst {
                // A later ingest fanout can reach other installations, but never resend this MD to id.
                _ = try await persist(app, try product(now: discussion.issued, summary: "Changed after move"), at: .now.addingTimeInterval(1))
                try await MesoNotificationOutboxStore().dispatchPending(context: context(app))
                let fanout = try #require(app.queues.test.all(MesoNotificationSendJob.self).last)
                try await job.dequeue(context(app), fanout)
            }
            let rows = try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == id).all()
            #expect(rows.count == 1 && rows.first?.status == "sent")
            let sql = try #require(app.db as? any SQLDatabase)
            let origin = try #require(try await sql.raw("SELECT delivery_origin FROM notification_ledger WHERE installation_id = \(bind: id)").first())
            #expect(try origin.decode(column: "delivery_origin", as: String.self) == (eventFirst ? "alertDriven" : "presenceReconciliation"))
            #expect(await sender.tokens.filter { $0 == "meso-event-test-\(id)" }.count == 1)
        }
    }

    @Test("meso attempts record candidate, delivery, zero-candidate, and dedupe outcomes")
    func attemptDiagnostics() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let job = MesoNotificationSendJob(sender: MesoEventRecordingSender())

            try await job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            _ = try await installation(app, cell: cell)
            try await job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            try await job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))

            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$subjectID == discussion.productID)
                .sort(\.$attemptedAt, .ascending)
                .all()
            #expect(attempts.count == 3)
            #expect(attempts.allSatisfy { $0.subjectKindRaw == "spc-meso" && $0.$series.id == nil })
            #expect(attempts[0].candidateResolutionReached && attempts[0].candidateCount == 0)
            #expect(attempts[0].outcome == NotificationSendAttemptOutcome.noOp.rawValue)
            #expect(attempts[0].noOpReason == NotificationSendNoOpReason.zeroCandidates.rawValue)
            #expect(attempts[1].candidateCount == 1 && attempts[1].claimedCount == 1 && attempts[1].sentCount == 1)
            #expect(attempts[1].outcome == NotificationSendAttemptOutcome.delivered.rawValue)
            #expect(attempts[2].candidateCount == 1 && attempts[2].claimedCount == 0)
            #expect(attempts[2].outcome == NotificationSendAttemptOutcome.noOp.rawValue)
            #expect(attempts[2].noOpReason == NotificationSendNoOpReason.allCandidatesPreviouslyClaimed.rawValue)

            let debugRows = try await NotificationDebugModel.query(on: app.db)
                .filter(\.$subjectID == discussion.productID)
                .all()
            #expect(debugRows.count == 2)
            #expect(debugRows.contains { $0.recordKind == NotificationDebugRecordKind.previewNoCandidates.rawValue })
            #expect(debugRows.contains { $0.recordKind == NotificationDebugRecordKind.candidate.rawValue && $0.notificationLedgerID != nil })
        }
    }

    @Test("presence lookup applies meso exclusions and the disabled gate")
    func presenceEligibility() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            var excluded: [UUID] = []
            excluded.append(try await installation(app, cell: cell, preference: nil))
            excluded.append(try await installation(app, cell: cell, preference: false))
            excluded.append(try await installation(app, cell: cell, subscribed: false))
            excluded.append(try await installation(app, cell: cell, active: false))
            excluded.append(try await installation(app, cell: cell, capturedAt: .now.addingTimeInterval(-25 * 3600)))
            excluded.append(try await installation(app, cell: cell, auth: .denied))
            excluded.append(try await installation(app, cell: cell, resolution: 7))
            excluded.append(try await installation(app, cell: nil))
            excluded.append(try await installation(app, cell: cell + 1000))
            for id in excluded { #expect(try await reconcile(app, installationID: id).isEmpty) }
            let degraded = try await installation(app, cell: cell, capturedAt: .now.addingTimeInterval(-7 * 3600))
            #expect(try await reconcile(app, installationID: degraded).count == 1)
            app.mesoNotificationsEnabled = false
            #expect(try await reconcile(app, installationID: degraded).isEmpty)
            app.mesoNotificationsEnabled = true
            _ = try await persist(app, try product(now: discussion.issued.addingTimeInterval(-7200)), at: .now.addingTimeInterval(1))
            #expect(try await reconcile(app, installationID: degraded).isEmpty)
        }
    }

    @Test("presence sends recheck latest coverage and retain their constraint on retry")
    func constrainedPresenceRetry() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: cell)
            let payload = try #require(try await reconcile(app, installationID: id).first)
            try await move(app, installationID: id, cell: cell + 1000)
            let sender = MesoEventRecordingSender(failFirst: true)
            let job = MesoNotificationSendJob(sender: sender)
            try await job.dequeue(context(app), payload)
            #expect(await sender.tokens.isEmpty)
            try await move(app, installationID: id, cell: cell)
            await #expect(throws: NotificationDeliveryRetryableError.self) { try await job.dequeue(context(app), payload) }
            let other = try await installation(app, cell: cell)
            try await job.dequeue(retryContext(app, payload: payload), payload)
            #expect(await sender.tokens == ["meso-event-test-\(id)", "meso-event-test-\(id)"])
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == other).count() == 0)
        }
    }

    @Test("simultaneous event-first and presence-first sends have one winner")
    func concurrentDiscoveryPaths() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: cell)
            let presence = try #require(try await reconcile(app, installationID: id).first)
            let sender = MesoEventRecordingSender()
            let job = MesoNotificationSendJob(sender: sender)
            async let eventSend: Void = job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            async let presenceSend: Void = job.dequeue(context(app), presence)
            _ = try await (eventSend, presenceSend)
            #expect(await sender.tokens == ["meso-event-test-\(id)"])
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == id).count() == 1)
        }
    }

    @Test("legacy queued meso payloads remain unconstrained")
    func legacyPayload() throws {
        let payload = MesoNotificationSendPayload(issueYear: 2026, number: 9875)
        let data = try JSONEncoder().encode(payload)
        #expect(try JSONDecoder().decode(MesoNotificationSendPayload.self, from: data).installationID == nil)
    }

    @Test("disabled gate prevents intents, handoffs, and manually queued sends")
    func disabled() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = false
            let cell = try await persist(app, discussion)
            try await installation(app, cell: cell)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 0)
            app.mesoNotificationsEnabled = true
            _ = try await persist(app, discussion)
            app.mesoNotificationsEnabled = false
            try await MesoNotificationOutboxStore().dispatchPending(context: context(app))
            #expect(app.queues.test.all(MesoNotificationSendJob.self).isEmpty)
            let sender = MesoEventRecordingSender()
            try await MesoNotificationSendJob(sender: sender).dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            #expect(await sender.tokens.isEmpty)
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 0)
        }
    }

    @Test("H3 selection excludes unknown capability, opt-out, inactive, unsubscribed, stale, denied, wrong-resolution and nonmatching devices")
    func eligibilityAndReplay() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let fresh = try await installation(app, cell: cell)
            let degraded = try await installation(app, cell: cell, capturedAt: .now.addingTimeInterval(-7 * 3600))
            try await installation(app, cell: cell, preference: nil)
            try await installation(app, cell: cell, preference: false)
            try await installation(app, cell: cell, subscribed: false)
            try await installation(app, cell: cell, active: false)
            try await installation(app, cell: cell, capturedAt: .now.addingTimeInterval(-25 * 3600))
            try await installation(app, cell: cell, auth: .denied)
            try await installation(app, cell: cell, resolution: 7)
            try await installation(app, cell: nil)
            try await installation(app, cell: cell + 1000)
            try await MesoNotificationOutboxStore().dispatchPending(context: context(app))
            let payload = try #require(app.queues.test.all(MesoNotificationSendJob.self).first)
            #expect(app.queues.test.all(NotificationSendJob.self).isEmpty)
            let sender = MesoEventRecordingSender()
            let job = MesoNotificationSendJob(sender: sender)
            try await job.dequeue(context(app), payload)
            try await job.dequeue(context(app), payload)
            let changed = try product(now: discussion.issued, summary: "Updated canonical content")
            _ = try await persist(app, changed, at: .now.addingTimeInterval(1))
            try await MesoNotificationOutboxStore().dispatchPending(context: context(app))
            let updatedPayload = try #require(app.queues.test.all(MesoNotificationSendJob.self).last)
            try await job.dequeue(context(app), updatedPayload)
            #expect(await sender.tokens.sorted() == ["meso-event-test-\(fresh)", "meso-event-test-\(degraded)"].sorted())
            #expect(await sender.payloads.allSatisfy { $0.productKind == .mesoscaleDiscussion && $0.resourceID == discussion.productID })
            let rows = try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).all()
            #expect(rows.count == 2 && rows.allSatisfy { $0.status == "sent" && $0.subject?.revisionID == "initial" })
            _ = try await persist(app, changed, at: .now.addingTimeInterval(2))
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 1)
        }
    }

    @Test("expired and not-yet-active discussions cannot emit intents or sends", arguments: [-7200.0, 7200.0])
    func inactive(offset: Double) async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let inactive = try product(now: discussion.issued.addingTimeInterval(offset))
            let cell = try await persist(app, inactive)
            try await installation(app, cell: cell)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 0)
            let sender = MesoEventRecordingSender()
            try await MesoNotificationSendJob(sender: sender).dequeue(context(app), .init(issueYear: inactive.issueYear, number: inactive.number))
            #expect(await sender.tokens.isEmpty)
        }
    }

    @Test("transient send failure retries the same owned claim and excludes new candidates")
    func retryOwnership() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: cell)
            let sender = MesoEventRecordingSender(failFirst: true)
            let job = MesoNotificationSendJob(sender: sender)
            let payload = MesoNotificationSendPayload(issueYear: discussion.issueYear, number: discussion.number)
            await #expect(throws: NotificationDeliveryRetryableError.self) { try await job.dequeue(context(app), payload) }
            let original = try #require(try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).first())
            #expect(original.status == "retrying")
            let other = try await installation(app, cell: cell)
            try await job.dequeue(retryContext(app, payload: payload), payload)
            let rows = try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).all()
            #expect(rows.count == 1 && rows.first?.id == original.id && rows.first?.status == "sent")
            #expect(await sender.tokens == ["meso-event-test-\(id)", "meso-event-test-\(id)"])
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == other).count() == 0)
        }
    }

    @Test("rollout disable terminalization is recorded as a failed retry attempt")
    func disabledRetryRecordsFailure() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            _ = try await installation(app, cell: try await persist(app, discussion))
            let sender = MesoEventRecordingSender(failFirst: true)
            let job = MesoNotificationSendJob(sender: sender)
            let payload = MesoNotificationSendPayload(issueYear: discussion.issueYear, number: discussion.number)
            await #expect(throws: NotificationDeliveryRetryableError.self) { try await job.dequeue(context(app), payload) }

            app.mesoNotificationsEnabled = false
            try await job.dequeue(retryContext(app, payload: payload), payload)

            let ledger = try #require(try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$subjectID == discussion.productID).first())
            #expect(ledger.status == "failed")
            let attempt = try #require(try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$subjectID == discussion.productID).sort(\.$attemptedAt, .descending).first())
            #expect(attempt.outcome == NotificationSendAttemptOutcome.failed.rawValue)
            #expect(attempt.failedCount == 1)
            #expect(attempt.noOpReason == nil)
        }
    }

    @Test("a queued retry recovers a pre-claim read failure even after outbox handoff is done")
    func preClaimRecovery() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: cell)
            try await MesoNotificationOutboxStore().dispatchPending(context: context(app))
            let payload = try #require(app.queues.test.all(MesoNotificationSendJob.self).first)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$subjectID == discussion.productID).first()?.state == "done")
            let sender = MesoEventRecordingSender()
            let read = MesoEventFailingRead()
            let job = MesoNotificationSendJob(sender: sender, loadDiscussion: { sql, id, now in
                try await read.load(sql: sql, productID: id, now: now)
            })
            await #expect(throws: MesoEventFailingRead.TransientReadFailure.self) {
                try await job.dequeue(context(app), payload)
            }
            #expect(!(try await NotificationDeliveryStore().hasMesoClaims(issueYear: payload.issueYear,
                number: payload.number, retryOwnerID: payload.retryOwnerID, on: app.db)))
            #expect(await sender.tokens.isEmpty)
            let retry = try retryContext(app, payload: payload)
            try await job.dequeue(retry, payload)
            try await job.dequeue(retry, payload)
            #expect(await sender.tokens == ["meso-event-test-\(id)"])
            let rows = try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).all()
            #expect(rows.count == 1 && rows.first?.status == "sent")
        }
    }

    @Test("any owned claim blocks fresh discovery on a queue retry", arguments: ["claimed", "sent", "failed"])
    func postClaimBoundary(status: String) async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            let id = try await installation(app, cell: cell)
            let payload = MesoNotificationSendPayload(issueYear: discussion.issueYear, number: discussion.number)
            let store = NotificationDeliveryStore()
            let claim = try await store.claimMeso(installationID: id, issueYear: payload.issueYear,
                number: payload.number, mode: .h3, reason: .new, freshnessState: .fresh,
                retryOwnerID: payload.retryOwnerID, origin: .alertDriven, on: app.db)
            if status == "sent" { try await store.completeSent(claimID: claim.id, on: app.db) }
            if status == "failed" { try await store.completeFailed(claimID: claim.id, apnsErrorCode: "Terminal", on: app.db) }
            #expect(try await store.hasMesoClaims(issueYear: payload.issueYear, number: payload.number,
                retryOwnerID: payload.retryOwnerID, on: app.db))
            #expect(!(try await store.hasMesoClaims(issueYear: payload.issueYear, number: payload.number + 1,
                retryOwnerID: payload.retryOwnerID, on: app.db)))
            #expect(!(try await store.hasMesoClaims(issueYear: payload.issueYear, number: payload.number,
                retryOwnerID: "another-owner", on: app.db)))
            let later = try await installation(app, cell: cell)
            let sender = MesoEventRecordingSender()
            try await MesoNotificationSendJob(sender: sender).dequeue(retryContext(app, payload: payload), payload)
            #expect(await sender.tokens.isEmpty)
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$deviceInstallation.$id == later).count() == 0)
            #expect(try await NotificationLedgerModel.find(try #require(claim.id), on: app.db)?.status == status)
        }
    }

    @Test("outbox claim and completion fence recover an expired lease without duplicate delivery")
    func outboxRecovery() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            try await installation(app, cell: cell)
            let store = MesoNotificationOutboxStore()
            let now = Date().addingTimeInterval(1)
            let first = try #require(try await store.claim(now: now, on: app.db).first)
            #expect(try await store.claim(now: now, on: app.db).isEmpty)
            let recovered = try #require(try await store.claim(now: now.addingTimeInterval(301), on: app.db).first)
            try await store.complete(first, on: app.db)
            #expect(try await ArcusNotificationOutboxModel.find(first.id, on: app.db)?.state == "processing")
            try await store.complete(recovered, on: app.db)
            #expect(try await ArcusNotificationOutboxModel.find(first.id, on: app.db)?.state == "done")
            let sender = MesoEventRecordingSender()
            let job = MesoNotificationSendJob(sender: sender)
            for _ in 0..<2 {
                try await job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            }
            #expect(await sender.tokens.count == 1)
        }
    }

    @Test("ingest enqueues after commit and coverage failure rolls back intent creation")
    func ingestAndRollback() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            app.spcMesoClient = MesoEventClient(discussion: discussion)
            try await IngestSPCMesoJob().dequeue(context(app), .init(runLabel: "meso-event-test-" + discussion.productID))
            #expect(app.queues.test.all(MesoNotificationSendJob.self).count == 1)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == discussion.productID).first()?.state == "done")
            try await cleanup(app, productID: discussion.productID)
            let failing = SPCMesoIngestPersistence(buildCoverage: { _ in throw Abort(.unprocessableEntity) })
            await #expect(throws: Abort.self) {
                _ = try await failing.persist([discussion], on: app.db, seenAt: .now, enqueueNotifications: true)
            }
            #expect(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == discussion.productID).count() == 0)
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 0)
        }
    }

    @Test("concurrent outbox drains and send jobs share one delivery authority")
    func concurrentWorkersAndScheduledRecovery() async throws {
        try await fixture { app, discussion in
            app.mesoNotificationsEnabled = true
            let cell = try await persist(app, discussion)
            try await installation(app, cell: cell)
            let outbox = MesoNotificationOutboxStore()
            async let a = outbox.claim(on: app.db)
            async let b = outbox.claim(on: app.db)
            let claims = try await a + b
            #expect(claims.count == 1)
            let claim = try #require(claims.first)
            try await outbox.complete(claim, error: "Injected enqueue failure", now: .now.addingTimeInterval(-31), on: app.db)
            try await DispatchMesoNotificationsScheduledJob().run(context: context(app))
            let payload = try #require(app.queues.test.all(MesoNotificationSendJob.self).first)
            #expect(app.queues.test.all(MesoNotificationSendJob.self).count == 1)
            let sender = MesoEventGatedSender()
            let job = MesoNotificationSendJob(sender: sender)
            async let first: Void = job.dequeue(context(app), payload)
            await sender.waitForAttempt()
            // The first sender is suspended with its durable claim outstanding;
            // another independently owned job must finish without calling APNs.
            try await job.dequeue(context(app), .init(issueYear: discussion.issueYear, number: discussion.number))
            #expect(await sender.attempts == 1)
            await sender.release()
            try await first
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).count() == 1)
            #expect(try await NotificationLedgerModel.query(on: app.db).filter(\.$subjectID == discussion.productID).first()?.status == "sent")
        }
    }
}

private struct MesoEventClient: SPCMesoClient {
    let discussion: MesoscaleDiscussionPayload
    func fetchDiscussions() async throws -> [MesoscaleDiscussionPayload] { [discussion] }
}

private actor MesoEventFailingRead {
    enum TransientReadFailure: Error { case injected }
    private var failFirst = true
    func load(sql: any SQLDatabase, productID: String, now: Date) async throws -> MesoscaleDiscussionPayload? {
        if failFirst { failFirst = false; throw TransientReadFailure.injected }
        return try await loadMesos(sql: sql, productID: productID, h3: nil, evaluatedAt: now).first
    }
}

private actor MesoEventRecordingSender: NotificationSender {
    private(set) var tokens: [String] = []
    private(set) var payloads: [HotAlertAPNsPayload] = []
    private var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func sendNotification(app: Application, with details: AlertDetails, hotAlertPayload: HotAlertAPNsPayload,
                          to device: String, environment: APNsEnvironment) async throws {
        tokens.append(device)
        payloads.append(hotAlertPayload)
        if failFirst { failFirst = false; throw TestTransportFailure.transient }
    }
    private enum TestTransportFailure: Error { case transient }
}

private actor MesoEventGatedSender: NotificationSender {
    private(set) var attempts = 0
    private var attemptWaiter: CheckedContinuation<Void, Never>?
    private var sendWaiter: CheckedContinuation<Void, Never>?

    func waitForAttempt() async {
        if attempts > 0 { return }
        await withCheckedContinuation { attemptWaiter = $0 }
    }
    func release() { sendWaiter?.resume(); sendWaiter = nil }
    func sendNotification(app: Application, with details: AlertDetails, hotAlertPayload: HotAlertAPNsPayload,
                          to device: String, environment: APNsEnvironment) async throws {
        attempts += 1
        await withCheckedContinuation { continuation in
            sendWaiter = continuation
            attemptWaiter?.resume()
            attemptWaiter = nil
        }
    }
}
