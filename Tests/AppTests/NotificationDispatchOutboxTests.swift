@testable import App
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues

@Suite("Notification dispatch outbox leases", .serialized)
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
                let id = try await insert(series: series, availableAt: .distantPast, on: app.db)
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
