@testable import App
import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues

@Suite("Notification dispatch outbox leases", .serialized, .sharedDatabase)
struct NotificationDispatchOutboxTests {
    private let store = NotificationDispatchOutboxStore()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withApp(test: (Application) async throws -> Void) async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            app.queues.use(.test)
            try await test(app)
        }
    }

    private func seed(on db: any Database) async throws -> UUID {
        let id = UUID()
        try await ArcusSeriesModel(
            id: id, source: "nws", event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(id)",
            currentRevisionUrn: "urn:oid:\(id)", currentRevisionSent: now,
            messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
            state: "active", lastSeenActive: now, severity: "severe",
            urgency: "immediate", certainty: "observed", ugcCodes: []
        ).create(on: db)
        return id
    }

    private func insert(series: UUID, mode: String = "ugc", state: String = "ready", attempts: Int = 0,
                        availableAt: Date? = nil, on db: any Database) async throws -> UUID {
        let row = ArcusNotificationOutboxModel(
            series: series, revisionUrn: "urn:oid:\(UUID())", mode: mode,
            reason: "new", state: state, attempts: attempts,
            lastError: "previous error", availableAt: availableAt ?? now
        )
        try await row.create(on: db)
        return try row.requireID()
    }

    private func isolate(on db: any Database) async throws {
        try await ArcusNotificationOutboxModel.query(on: db).set(\.$state, to: "done").update()
    }

    @Test("bounded ordered claims isolate modes and recover only expired leases")
    func claimEligibility() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { db in
                try await isolate(on: db)
                let series = try await seed(on: db)
                let first = try await insert(series: series, availableAt: now.addingTimeInterval(-2), on: db)
                let second = try await insert(series: series, availableAt: now.addingTimeInterval(-1), on: db)
                _ = try await insert(series: series, availableAt: now.addingTimeInterval(1), on: db)
                _ = try await insert(series: series, state: "processing", availableAt: now.addingTimeInterval(30), on: db)
                let expired = try await insert(series: series, state: "processing", on: db)
                let h3 = try await insert(series: series, mode: "h3", on: db)
                _ = try await insert(series: series, state: "dead", on: db)
                _ = try await insert(series: series, state: "done", on: db)

                let batch = try await store.claim(mode: "ugc", limit: 2, now: now, on: db)
                #expect(batch.map(\.id) == [first, second])
                for claim in batch {
                    let row = try #require(try await ArcusNotificationOutboxModel.find(claim.id, on: db))
                    #expect(row.state == "processing")
                    #expect(row.availableAt == now.addingTimeInterval(300))
                    #expect(row.attempts == 0)
                }
                #expect(try await store.claim(mode: "ugc", limit: 10, now: now, on: db).map(\.id) == [expired])
                #expect(try await store.claim(mode: "ugc", limit: 10, now: now, on: db).isEmpty)
                #expect(try await store.claim(mode: "h3", limit: 10, now: now, on: db).map(\.id) == [h3])
                #expect(try await store.claim(mode: "ugc", limit: 0, now: now, on: db).isEmpty)
            }
        }
    }

    @Test("overlapping claims skip locked rows and concurrent claims are disjoint")
    func concurrentClaims() async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            let mode = "test-\(UUID())"
            do {
                var ids = Set<UUID>()
                for _ in 0..<6 { ids.insert(try await insert(series: series, mode: mode, on: app.db)) }
                // Keep the first transaction open while a separate connection claims.
                try await app.db.transaction { db in
                    let locked = try await store.claim(mode: mode, limit: 2, now: now, on: db)
                    let other = try await store.claim(mode: mode, limit: 2, now: now, on: app.db)
                    #expect(locked.count == 2)
                    #expect(other.count == 2)
                    #expect(Set(locked.map(\.id)).isDisjoint(with: other.map(\.id)))
                }
                async let a = store.claim(mode: mode, limit: 1, now: now, on: app.db)
                async let b = store.claim(mode: mode, limit: 1, now: now, on: app.db)
                let (left, right) = try await (a, b)
                #expect(left.count == 1 && right.count == 1)
                #expect(left.first?.id != right.first?.id)
                #expect(ids.contains(try #require(left.first).id))
                #expect(ids.contains(try #require(right.first).id))
                #expect(try await store.claim(mode: mode, limit: 6, now: now, on: app.db).isEmpty)
            } catch {
                try? await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
                throw error
            }
            try await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
        }
    }

    @Test("handoff completion increments once, backs off, and exhausts at three attempts")
    func completionOutcomes() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { db in
                try await isolate(on: db)
                let series = try await seed(on: db)
                let id = try await insert(series: series, on: db)
                let initial = try #require(try await store.claim(mode: "ugc", limit: 1, now: now, on: db).first)
                #expect(try await store.complete(initial, error: "redis unavailable", now: now, on: db))
                var row = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                #expect(row.state == "ready" && row.attempts == 1)
                #expect(row.lastError == "redis unavailable")
                #expect(row.availableAt == now.addingTimeInterval(30))
                #expect(try await store.claim(mode: "ugc", limit: 1, now: now, on: db).isEmpty)
                let retry = try #require(try await store.claim(mode: "ugc", limit: 1, now: now.addingTimeInterval(30), on: db).first)
                #expect(try await store.complete(retry, error: "still unavailable", now: now.addingTimeInterval(30), on: db))
                row = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                #expect(row.state == "ready" && row.attempts == 2)
                #expect(row.availableAt == now.addingTimeInterval(150))
                let last = try #require(try await store.claim(mode: "ugc", limit: 1, now: now.addingTimeInterval(150), on: db).first)
                #expect(try await store.complete(last, error: "exhausted", now: now, on: db))
                row = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                #expect(row.state == "dead" && row.attempts == 3 && row.lastError == "exhausted")
                #expect(!(try await store.complete(last, now: now, on: db)))

                let successID = try await insert(series: series, on: db)
                let success = try #require(try await store.claim(mode: "ugc", limit: 1, now: now, on: db).first)
                #expect(try await store.complete(success, now: now, on: db))
                row = try #require(try await ArcusNotificationOutboxModel.find(successID, on: db))
                #expect(row.state == "done" && row.attempts == 1 && row.lastError == nil)
                #expect(!(try await store.complete(success, error: "late failure", on: db)))
            }
        }
    }

    @Test("old success and failure cannot overwrite a recovered lease")
    func staleCompletion() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { db in
                try await isolate(on: db)
                let series = try await seed(on: db)
                let id = try await insert(series: series, on: db)
                let old = try #require(try await store.claim(mode: "ugc", limit: 1, now: now, on: db).first)
                let recovered = try #require(try await store.claim(mode: "ugc", limit: 1, now: now.addingTimeInterval(300), on: db).first)
                #expect(old.lease != recovered.lease)
                #expect(!(try await store.complete(old, now: now, on: db)))
                #expect(!(try await store.complete(old, error: "stale error", now: now, on: db)))
                let row = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                #expect(row.state == "processing" && row.attempts == 0)
                #expect(row.availableAt == now.addingTimeInterval(600))
                #expect(try await store.complete(recovered, now: now.addingTimeInterval(300), on: db))
            }
        }
    }

    @Test("replay preserves processing bookkeeping, fences stale reads, and resets dead rows")
    func replayProtection() async throws {
        try await withApp { app in
            try await withRollbackTransaction(on: app) { db in
                try await isolate(on: db)
                let series = try await seed(on: db)
                let id = try await insert(series: series, attempts: 1, on: db)
                let beforeClaim = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                let claim = try #require(try await store.claim(mode: "ugc", limit: 1, now: now, on: db).first)
                #expect(!(try await store.resetForReplay(id: beforeClaim.requireID(), reason: .update, now: now, on: db)))
                #expect(!(try await DispatchAgent.enqueueNotificationDispatchOutbox(
                    revisionUrn: claim.revisionUrn, seriesId: series, reason: .update, mode: .ugc, on: db, logger: app.logger
                )))
                // Expired processing recovery also belongs solely to claim().
                #expect(!(try await store.resetForReplay(id: id, reason: .update, now: now.addingTimeInterval(300), on: db)))
                let row = try #require(try await ArcusNotificationOutboxModel.find(id, on: db))
                #expect(row.state == "processing" && row.attempts == 1 && row.reason == "new")
                #expect(row.lastError == "previous error" && row.availableAt == now.addingTimeInterval(300))
                let deadID = try await insert(series: series, state: "dead", attempts: 3, on: db)
                let dead = try #require(try await ArcusNotificationOutboxModel.find(deadID, on: db))
                #expect(try await DispatchAgent.enqueueNotificationDispatchOutbox(
                    revisionUrn: dead.revisionUrn, seriesId: series, reason: .update, mode: .ugc, on: db, logger: app.logger
                ))
                let reset = try #require(try await ArcusNotificationOutboxModel.find(deadID, on: db))
                #expect(reset.state == "ready" && reset.attempts == 0 && reset.lastError == nil && reset.reason == "update")

                // Replay's unlocked read can precede the active handoff's terminal failure.
                let racingID = try await insert(series: series, mode: "h3", attempts: 2, on: db)
                let racingClaim = try #require(try await store.claim(mode: "h3", limit: 1, now: now, on: db).first)
                let processingSnapshot = try #require(try await ArcusNotificationOutboxModel.find(racingID, on: db))
                #expect(processingSnapshot.state == "processing")
                #expect(try await store.complete(racingClaim, error: "exhausted", now: now, on: db))
                #expect(try await DispatchAgent.handleExistingNotificationDispatchOutbox(
                    processingSnapshot, revisionUrn: racingClaim.revisionUrn,
                    reason: .update, mode: .h3, on: db, logger: app.logger
                ))
                let replayed = try #require(try await ArcusNotificationOutboxModel.find(racingID, on: db))
                #expect(replayed.state == "ready" && replayed.attempts == 0 && replayed.lastError == nil)
            }
        }
    }

    @Test("dispatch observes committed processing state without SQL locks during queue handoff")
    func queueHandoffBoundary() async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            do {
                let revision = "urn:oid:\(series)"
                #expect(try await DispatchAgent.enqueueNotificationDispatchOutbox(
                    revisionUrn: revision, seriesId: series, reason: .new, mode: .ugc,
                    on: app.db, logger: app.logger
                ))
                let outbox = try #require(try await ArcusNotificationOutboxModel.query(on: app.db)
                    .filter(\.$series.$id == series).first())
                #expect(outbox.subject == .nws(seriesID: series, revisionUrn: revision))
                #expect(outbox.subjectKindRaw == "nws")
                let id = try outbox.requireID()
                let probe = NotificationHandoffProbe(id: id, db: app.db)
                app.queues.add(probe)
                let context = QueueContext(
                    queueName: QueueName(string: "scheduled"), configuration: app.queues.configuration,
                    application: app, logger: app.logger, on: app.eventLoopGroup.any()
                )
                _ = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "ugc")
                #expect(await probe.observedProcessing)
                let row = try #require(try await ArcusNotificationOutboxModel.find(id, on: app.db))
                #expect(row.state == "done" && row.attempts == 1 && row.lastError == nil)
                let payloads = app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == series }
                #expect(payloads.count == 1)
                #expect(payloads.first?.mode == .ugc && payloads.first?.reason == .new)
                let payload = try #require(payloads.first)
                #expect(payload.subject == .nws(seriesID: series, revisionUrn: row.revisionUrn))
                #expect(payload.origin == .alertDriven)
                let queuedAt = try #require(payload.queuedAt)
                // The candidate query has no codes, so no APNs dependency is reached.
                try await NotificationSendJob().dequeue(context, payload)
                let sql = try #require(app.db as? any SQLDatabase)
                let persisted = try #require(try await sql.raw("""
                    SELECT queued_at FROM notification_pipeline_timings
                    WHERE delivery_attempt_id = \(bind: payload.deliveryAttemptId)
                    """).first())
                #expect(abs(try persisted.decode(column: "queued_at", as: Date.self).timeIntervalSince(queuedAt)) < 0.000_001)
                _ = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "ugc")
                #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == series }.count == 1)
            } catch {
                try? await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
                throw error
            }
            try await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
        }
    }

    private func context(_ app: Application) -> QueueContext {
        .init(queueName: .init(string: "scheduled"), configuration: app.queues.configuration,
              application: app, logger: app.logger, on: app.eventLoopGroup.any())
    }

    @Test("recovery revisits failed H3 handoff after unchanged sweeps and quiet weather")
    func independentH3Recovery() async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            try await withRecoveryFixtures(series: series, app: app) {
                let id = try await insert(series: series, mode: "h3", availableAt: .distantPast, on: app.db)
                let context = context(app)
                app.queues.use(custom: FailingNotificationQueueDriver())
                try await RecoverNWSOutboxScheduledJob().run(context: context)
                let failed = try #require(try await ArcusNotificationOutboxModel.find(id, on: app.db))
                #expect(failed.state == "ready" && failed.attempts == 1)
                let due = failed.availableAt
                app.queues.use(.test)
                // Identical accepted weather is repeatedly acquired; it cannot create fresh intent.
                let events = [recoveryEvent(owner: series)]
                app.nwsIngestService = RecoveryWeather(events: events)
                for _ in 0..<10 {
                    try await IngestNWSAlertsJob().dequeue(context, .init(runLabel: "issue383-\(series)"))
                }
                #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == series }.isEmpty)
                try await RecoverNWSOutboxScheduledJob().run(context: context)
                #expect(try await ArcusNotificationOutboxModel.find(id, on: app.db)?.availableAt == due)
                // Advance only this persisted deadline, avoiding sleeps or a process-global clock.
                try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$id == id)
                    .set(\.$availableAt, to: .distantPast).update()
                // Quiet/stopped interval: no tick means no handoff, even when due.
                #expect(try await ArcusNotificationOutboxModel.find(id, on: app.db)?.state == "ready")
                app.nwsIngestService = RecoveryWeather(events: [])
                try await RecoverNWSOutboxScheduledJob().run(context: context)
                #expect(try await ArcusNotificationOutboxModel.find(id, on: app.db)?.state == "done")
                #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == series }.count == 1)
            }
        }
    }

    @Test("recovery drains target and UGC through repeated acquisition failures and abandoned H3 lease")
    func upstreamFailureAndRestart() async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            try await withRecoveryFixtures(series: series, app: app) {
                let context = context(app)
                let ugc = try await insert(series: series, availableAt: .distantPast, on: app.db)
                let h3 = try await insert(series: series, mode: "h3", availableAt: .distantPast, on: app.db)
                let abandoned = try #require(try await store.claim(mode: "h3", limit: 1, on: app.db).first)
                let future = try await insert(series: series, mode: "h3", availableAt: .distantFuture, on: app.db)
                let dead = try await insert(series: series, mode: "h3", state: "dead", on: app.db)
                let done = try await insert(series: series, mode: "h3", state: "done", on: app.db)
                try await ArcusTargetDispatchOutboxModel(revisionUrn: "urn:oid:recovery-\(series)", seriesId: series,
                    payload: .init(seriesId: series, revisionUrn: "urn:oid:recovery-\(series)",
                                   geometry: .point(lon: -104, lat: 39), reason: .new)).create(on: app.db)
                app.nwsIngestService = RecoveryWeather(events: nil)
                for _ in 0..<3 {
                    await #expect(throws: NWSIngestServiceError.self) {
                        try await IngestNWSAlertsJob().dequeue(context, .init(runLabel: "issue383-\(series)"))
                    }
                }
                #expect(app.queues.test.all(TargetEventRevisionJob.self).isEmpty)
                try await RecoverNWSOutboxScheduledJob().run(context: context)
                #expect(app.queues.test.all(TargetEventRevisionJob.self).filter { $0.seriesId == series }.count == 1)
                #expect(try await ArcusNotificationOutboxModel.find(ugc, on: app.db)?.state == "done")
                #expect(try await ArcusNotificationOutboxModel.find(h3, on: app.db)?.state == "processing")
                try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$id == h3)
                    .set(\.$availableAt, to: .distantPast).update()
                // A fresh job instance models restart; the durable deadline is the authority.
                try await RecoverNWSOutboxScheduledJob().run(context: context)
                #expect(try await ArcusNotificationOutboxModel.find(h3, on: app.db)?.state == "done")
                #expect(!(try await store.complete(abandoned, error: "late old owner", on: app.db)))
                #expect(try await ArcusNotificationOutboxModel.find(future, on: app.db)?.state == "ready")
                #expect(try await ArcusNotificationOutboxModel.find(dead, on: app.db)?.state == "dead")
                #expect(try await ArcusNotificationOutboxModel.find(done, on: app.db)?.state == "done")
            }
        }
    }

    @Test("scheduled and ingest target handoffs preserve retry state and delivery", arguments: [false, true])
    func overlappingRecovery(failFirstHandoff: Bool) async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            try await withRecoveryFixtures(series: series, app: app) {
                let context = context(app)
                let revision = "urn:oid:\(series)"
                let geometry = GeoShape.polygon(rings: [[.init(lon: -105, lat: 39), .init(lon: -104.9, lat: 39),
                    .init(lon: -104.9, lat: 39.1), .init(lon: -105, lat: 39)]])
                try await ArcusTargetDispatchOutboxModel(revisionUrn: revision, seriesId: series,
                    payload: .init(seriesId: series, revisionUrn: revision, geometry: geometry, reason: .new))
                    .create(on: app.db)
                let barrier = RecoveryTargetBarrier()
                app.queues.add(barrier)
                async let scheduled: Void = RecoverNWSOutboxScheduledJob().run(context: context)
                async let ingest = IngestNWSAlertsJob().dispatchPendingTargetJobs(context: context)
                _ = try await (scheduled, ingest)
                let targets = await barrier.targets.filter { $0.seriesId == series }
                #expect(targets.count == 2) // Deliberately force the older target handoff race.
                if failFirstHandoff {
                    app.queues.use(custom: FailingNotificationQueueDriver())
                    try await TargetEventRevisionJob().dequeue(context, targets[0])
                    let failed = try #require(try await ArcusNotificationOutboxModel.query(on: app.db)
                        .filter(\.$series.$id == series).first())
                    #expect(failed.state == "ready" && failed.attempts == 1)
                    let due = failed.availableAt
                    app.queues.use(.test)
                    // The second target copy must not bypass the first handoff's backoff.
                    try await TargetEventRevisionJob().dequeue(context, targets[1])
                    let afterDuplicate = try #require(try await ArcusNotificationOutboxModel.find(failed.requireID(), on: app.db))
                    #expect(afterDuplicate.state == "ready")
                    #expect(afterDuplicate.attempts == 1 && afterDuplicate.availableAt == due)
                    return
                }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for payload in targets { group.addTask { try await TargetEventRevisionJob().dequeue(context, payload) } }
                    group.addTask { try await RecoverNWSOutboxScheduledJob().run(context: context) }
                    try await group.waitForAll()
                }
                let rows = try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$series.$id == series).all()
                #expect(rows.count == 1 && rows.first?.state == "done")
                let coverage = try #require(try await ArcusGeolocationModel.query(on: app.db)
                    .filter(\.$series.$id == series).first())
                let cell = try #require(coverage.h3Cells.first)
                let installation = UUID()
                try await DeviceInstallationModel(installationId: installation, apnsDeviceToken: "recovery-test",
                    apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26", appVersion: "1",
                    buildNumber: "1", locationAuth: .always).create(on: app.db)
                do {
                    try await DevicePresenceModel(installationId: installation, capturedAt: .now,
                        locationAgeSeconds: 0, horizontalAccuracyMeters: 10, cellScheme: .h3,
                        h3Cell: cell, h3Resolution: 8, county: nil, zone: nil, fireZone: nil,
                        source: .unknown, countyLabel: nil, fireZoneLabel: nil).create(on: app.db)
                    let payload = try #require(await barrier.sends.first { $0.seriesId == series })
                    let sender = RecoverySender()
                    // Duplicate Redis handoff after a lost completion still crosses one delivery claim.
                    try await NotificationSendJob(sender: sender).dequeue(context, payload)
                    try await NotificationSendJob(sender: sender).dequeue(context, payload)
                    #expect(await sender.count == 1)
                    #expect(try await NotificationLedgerModel.query(on: app.db)
                        .filter(\.$series.$id == series).count() == 1)
                } catch {
                    try? await DeviceInstallationModel.find(installation, on: app.db)?.delete(on: app.db)
                    throw error
                }
                try await DeviceInstallationModel.find(installation, on: app.db)?.delete(on: app.db)
            }
        }
    }

    @Test("duplicate automatic targets preserve failed and exhausted H3/UGC handoffs",
          arguments: [NotificationTargetMode.h3, .ugc], [false, true])
    func duplicateTargetFailureState(mode: NotificationTargetMode, exhaust: Bool) async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            try await withRecoveryFixtures(series: series, app: app) {
                let context = context(app)
                let payload = TargetEventRevisionPayload(seriesId: series, revisionUrn: "urn:oid:\(series)",
                    geometry: .point(lon: -105, lat: 39), reason: .new)
                let job = TargetEventRevisionJob(buildCoverage: { _ in
                    mode == .h3 ? .supported(.init(cells: [123], h3Hash: "recovery", geometryHash: "recovery", resolution: 8))
                        : .unsupportedPoint
                })
                app.queues.use(custom: FailingNotificationQueueDriver())
                try await job.dequeue(context, payload)
                let failed = try #require(try await ArcusNotificationOutboxModel.query(on: app.db)
                    .filter(\.$series.$id == series).first())
                #expect(failed.mode == mode.rawValue && failed.state == "ready" && failed.attempts == 1)
                if exhaust {
                    // Drive the real completion transition through its terminal failure.
                    for _ in 0..<2 {
                        try await ArcusNotificationOutboxModel.query(on: app.db).filter(\.$id == failed.requireID())
                            .set(\.$availableAt, to: .distantPast).update()
                        try await RecoverNWSOutboxScheduledJob().run(context: context)
                    }
                }
                let before = try #require(try await ArcusNotificationOutboxModel.find(failed.requireID(), on: app.db))
                app.queues.use(.test)
                try await job.dequeue(context, payload)
                let after = try #require(try await ArcusNotificationOutboxModel.find(failed.requireID(), on: app.db))
                #expect(before.state == (exhaust ? "dead" : "ready"))
                #expect(after.state == before.state && after.attempts == before.attempts)
                #expect(after.availableAt == before.availableAt && after.lastError == before.lastError)
                #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == series }.isEmpty)
            }
        }
    }

    @Test("recovery cleanup preserves unrelated replay rows", arguments: [false, true])
    func recoveryCleanupOwnership(throwDuringTest: Bool) async throws {
        try await withApp { app in
            let owned = try await seed(on: app.db)
            let unrelated = try await seed(on: app.db)
            do {
                try await ArcusSeriesModel.query(on: app.db).filter(\.$id == unrelated)
                    .set(\.$currentRevisionUrn, to: "urn:oid:2.49.0.1.840.0.replay.alert.002").update()
                if throwDuringTest {
                    await #expect(throws: RecoveryFixtureError.self) {
                        try await withRecoveryFixtures(series: owned, app: app) { throw RecoveryFixtureError.expected }
                    }
                } else {
                    try await withRecoveryFixtures(series: owned, app: app) {}
                }
                #expect(try await ArcusSeriesModel.find(owned, on: app.db) == nil)
                #expect(try await ArcusSeriesModel.find(unrelated, on: app.db) != nil)
            } catch {
                try? await ArcusSeriesModel.find(owned, on: app.db)?.delete(on: app.db)
                try? await ArcusSeriesModel.find(unrelated, on: app.db)?.delete(on: app.db)
                throw error
            }
            try await ArcusSeriesModel.find(unrelated, on: app.db)?.delete(on: app.db)
        }
    }

    private func recoveryEvent(owner: UUID) -> ArcusEvent {
        ArcusEvent(
            urn: "urn:oid:issue383-\(owner)", source: .nws, kind: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/issue383-\(owner)", vtec: nil,
            messageType: .alert, state: .active, sent: now, effective: nil, onset: nil,
            expires: nil, ends: nil, lastSeenActive: now, severity: .severe,
            urgency: .immediate, certainty: .observed, geometry: nil, ugcCodes: [],
            title: "Recovery TEST", areaDesc: "Recovery TEST", rawRef: nil,
            category: "Met", event: "Tornado Warning", senderName: "Recovery TEST",
            headline: "Recovery TEST", description: "Recovery TEST", instructions: nil,
            response: "Shelter", status: "Actual", tornadoDetection: nil,
            tornadoDamageThreat: nil, maxWindGust: nil, maxHailSize: nil,
            windThreat: nil, hailThreat: nil, thunderstormDamageThreat: nil,
            flashFloodDetection: nil, flashFloodDamageThreat: nil
        )
    }

    private func withRecoveryFixtures(series: UUID, app: Application, test: () async throws -> Void) async throws {
        func cleanup() async throws {
            try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == "issue383-\(series)").delete()
            try await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
            try await ArcusSeriesModel.query(on: app.db)
                .filter(\.$sourceURL == "https://api.weather.gov/alerts/issue383-\(series)").delete()
        }
        do { try await test(); try await cleanup() }
        catch { try? await cleanup(); throw error }
    }

    @Test("a queue dispatch error persists one failed handoff with backoff")
    func queueHandoffFailure() async throws {
        try await withApp { app in
            let series = try await seed(on: app.db)
            do {
                let id = try await insert(series: series, mode: "h3", availableAt: .distantPast, on: app.db)
                app.queues.use(custom: FailingNotificationQueueDriver())
                let context = QueueContext(
                    queueName: QueueName(string: "scheduled"), configuration: app.queues.configuration,
                    application: app, logger: app.logger, on: app.eventLoopGroup.any()
                )
                let started = Date()
                let result = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "h3")
                #expect(result.failed >= 1)
                let row = try #require(try await ArcusNotificationOutboxModel.find(id, on: app.db))
                #expect(row.state == "ready" && row.attempts == 1 && row.lastError != nil)
                #expect(row.availableAt >= started.addingTimeInterval(30))
            } catch {
                try? await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
                throw error
            }
            try await ArcusSeriesModel.find(series, on: app.db)?.delete(on: app.db)
        }
    }
}

private actor NotificationHandoffProbe: AsyncJobEventDelegate {
    let id: UUID
    let db: any Database
    private(set) var observedProcessing = false

    init(id: UUID, db: any Database) {
        self.id = id
        self.db = db
    }

    func dispatched(job: JobEventData) async throws {
        guard job.jobName == NotificationSendJob.name else { return }
        // A separate connection can lock the row while Redis dispatch is awaited.
        try await db.transaction { transaction in
            let sql = try #require(transaction as? any SQLDatabase)
            let row = try #require(try await sql.raw("""
                SELECT state FROM notification_outbox WHERE id = \(bind: self.id) FOR UPDATE NOWAIT
                """).first())
            #expect(try row.decode(column: "state", as: String.self) == "processing")
        }
        #expect(job.queueName == ArcusQueueLane.send.rawValue)
        #expect(job.maxRetryCount == NotificationSendJob.maximumRetryCount)
        observedProcessing = true
    }
}

private struct FailingNotificationQueueDriver: QueuesDriver {
    func makeQueue(with context: QueueContext) -> any Queue { FailingNotificationQueue(context: context) }
    func shutdown() {}
}

private struct FailingNotificationQueue: AsyncQueue {
    let context: QueueContext

    func get(_ id: JobIdentifier) async throws -> JobData { throw Abort(.serviceUnavailable) }
    func set(_ id: JobIdentifier, to data: JobData) async throws { throw Abort(.serviceUnavailable) }
    func clear(_ id: JobIdentifier) async throws {}
    func pop() async throws -> JobIdentifier? { nil }
    func push(_ id: JobIdentifier) async throws { throw Abort(.serviceUnavailable) }
}

private struct RecoveryWeather: NWSIngestService {
    let events: [ArcusEvent]?
    func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent] {
        guard let events else { throw NWSIngestServiceError.unconfigured }
        return events
    }
}

private actor RecoveryTargetBarrier: AsyncJobEventDelegate {
    private var first: CheckedContinuation<Void, Never>?
    private var arrivals = 0
    private(set) var targets: [TargetEventRevisionPayload] = []
    private(set) var sends: [NotificationSendJobPayload] = []
    func dispatched(job: JobEventData) async throws {
        if job.jobName == NotificationSendJob.name {
            sends.append(try NotificationSendJob.parsePayload(job.payload))
        }
        guard job.jobName == TargetEventRevisionJob.name else { return }
        targets.append(try TargetEventRevisionJob.parsePayload(job.payload))
        arrivals += 1
        if arrivals == 1 {
            await withCheckedContinuation { first = $0 }
        } else if arrivals == 2 {
            first?.resume()
            first = nil
        }
    }
}

private actor RecoverySender: NotificationSender {
    private(set) var count = 0
    func sendNotification(app: Application, with: AlertDetails, hotAlertPayload: HotAlertAPNsPayload,
                          to: String, environment: APNsEnvironment) async throws { count += 1 }
}

private enum RecoveryFixtureError: Error { case expected }
