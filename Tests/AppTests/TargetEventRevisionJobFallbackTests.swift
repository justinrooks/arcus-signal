@testable import App
import ArcusCore
import Fluent
import Foundation
import Queues
import SQLKit
import Testing
import Vapor
import XCTQueues

@Suite("Target event revision fallback tests", .serialized)
struct TargetEventRevisionJobFallbackTests {
    private func withWorkerApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .worker)
            try await app.autoMigrate()
            app.queues.use(.test)
            try await deleteTargetFallbackFixtures(on: app.db)
            try await test(app)
            try await deleteTargetFallbackFixtures(on: app.db)
        } catch {
            Issue.record("Worker app bootstrap/test failed: \(String(reflecting: error))")
            try? await deleteTargetFallbackFixtures(on: app.db)
            try? await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
    }

    private func deleteTargetFallbackFixtures(on database: any Database) async throws {
        try await ArcusSeriesModel.query(on: database)
            .filter(\.$sourceURL, .equal, "https://api.weather.gov/alerts/test-target-fallback")
            .delete()
    }

    private func makeQueueContext(app: Application) -> QueueContext {
        QueueContext(
            queueName: QueueName(string: "test-target-fallback"),
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    private func makeSeries(id: UUID, revisionUrn: String, now: Date) -> ArcusSeriesModel {
        ArcusSeriesModel(
            id: id,
            source: EventSource.nws.rawValue,
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test-target-fallback",
            currentRevisionUrn: revisionUrn,
            currentRevisionSent: now,
            messageType: NWSAlertMessageType.alert.rawValue,
            contentFingerprint: String(repeating: "a", count: 64),
            state: EventState.active.rawValue,
            lastSeenActive: now,
            severity: EventSeverity.severe.rawValue,
            urgency: EventUrgency.immediate.rawValue,
            certainty: EventCertainty.observed.rawValue,
            ugcCodes: ["COC031"]
        )
    }

    private func makePolygonGeometry() -> GeoShape {
        .polygon(rings: [[
            .init(lon: -104.9903, lat: 39.7392),
            .init(lon: -104.9703, lat: 39.7392),
            .init(lon: -104.9803, lat: 39.7592),
            .init(lon: -104.9903, lat: 39.7392)
        ]])
    }

    private func h3Cover(for geometry: GeoShape) throws -> (geometryHash: String, h3Cells: [Int64], h3Hash: String) {
        guard case .supported(let coverage) = try H3CoverageBuilder.build(for: geometry) else {
            throw Abort(.badRequest, reason: "Test fixture requires polygon geometry.")
        }
        return (coverage.geometryHash, coverage.cells, coverage.h3Hash)
    }

    private struct TargetTiming: Decodable, Equatable {
        let queuedAt: Date?
        let startedAt: Date
        let completedAt: Date?
    }

    private func loadTiming(_ revision: String, on db: any Database) async throws -> TargetTiming {
        let sql = try #require(db as? any SQLDatabase)
        return try #require(try await sql.raw("""
            SELECT queued_at AS "queuedAt", started_at AS "startedAt", h3_completed_at AS "completedAt"
            FROM target_pipeline_timings WHERE revision_urn = \(bind: revision)
            """).first(decoding: TargetTiming.self))
    }

    @Test("concurrent target duplicates keep the winning send's target execution", arguments: [false, true])
    func duplicateTargetExecutionTiming(failWinningStart: Bool) async throws {
        try await withWorkerApp { app in
            let seriesID = UUID()
            let revisionUrn = "urn:oid:target-race-\(UUID())"
            let installationID = UUID()
            let cell = Int64.random(in: 1_000_000...2_000_000)
            let coverage = H3Coverage(cells: [cell], h3Hash: "race-h3", geometryHash: "race-geometry", resolution: 8)
            let a = TargetEventRevisionPayload(seriesId: seriesID, revisionUrn: revisionUrn,
                geometry: makePolygonGeometry(), reason: .new, queuedAt: .now)
            let b = TargetEventRevisionPayload(seriesId: seriesID, revisionUrn: revisionUrn,
                geometry: makePolygonGeometry(), reason: .new, queuedAt: .now)
            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(revisionUrn: revisionUrn, seriesId: seriesID, payload: a).create(on: app.db)
            try await DeviceInstallationModel(installationId: installationID, apnsDeviceToken: "race-token",
                apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26", appVersion: "1", buildNumber: "1", locationAuth: .always).create(on: app.db)
            try await DevicePresenceModel(installationId: installationID, capturedAt: .now,
                locationAgeSeconds: 0, horizontalAccuracyMeters: 10, cellScheme: .h3,
                h3Cell: cell, h3Resolution: 8, county: nil, zone: nil, fireZone: nil,
                source: .unknown, countyLabel: nil, fireZoneLabel: nil).create(on: app.db)
            let entered = AsyncStream<Void>.makeStream()
            let release = DispatchSemaphore(value: 0)
            let context = makeQueueContext(app: app)
            let slowJob = TargetEventRevisionJob(buildCoverage: { _ in
                entered.continuation.yield(())
                guard release.wait(timeout: .now() + 10) == .success else { throw Abort(.requestTimeout) }
                return .supported(coverage)
            })
            let slow = Task { try await slowJob.dequeue(context, a) }
            defer { release.signal() }
            var enteredIterator = entered.stream.makeAsyncIterator()
            _ = await enteredIterator.next()
            let fast = TargetEventRevisionJob(buildCoverage: { _ in .supported(coverage) })
            if failWinningStart {
                try await withPipelineTimingWriteFailure(table: "target_pipeline_timings", operation: "INSERT", seriesID: seriesID, on: app.db) {
                    try await fast.dequeue(context, b)
                }
            } else {
                try await fast.dequeue(context, b)
            }
            let sendPayload = try #require(app.queues.test.all(NotificationSendJob.self).first { $0.seriesId == seriesID })
            #expect(sendPayload.sourceTargetExecutionId == b.targetExecutionId)
            let sender = PipelineTimingSender()
            try await NotificationSendJob(sender: sender).dequeue(context, sendPayload)
            release.signal()
            try await slow.value
            let outbox = try #require(try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$series.$id == seriesID).first())
            #expect(outbox.sourceTargetExecutionId == b.targetExecutionId)
            #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == seriesID }.count == 1)
            #expect(await sender.count == 1)
            let sql = try #require(app.db as? any SQLDatabase)
            struct Waterfall: Decodable {
                let source: UUID
                let targetStart: Date?
                let h3Complete: Date?
                let queued: Date
                let sendStart: Date
                let resolved: Date
                let apns: Date
            }
            let joined = try #require(try await sql.raw("""
                SELECT n.source_target_execution_id AS source, t.started_at AS "targetStart",
                       t.h3_completed_at AS "h3Complete", n.queued_at AS queued,
                       n.started_at AS "sendStart", n.candidate_resolution_completed_at AS resolved,
                       l.first_apns_attempt_started_at AS apns
                FROM notification_ledger l
                JOIN notification_pipeline_timings n ON n.delivery_attempt_id::text = LOWER(l.retry_owner_id)
                LEFT JOIN target_pipeline_timings t ON t.execution_id = n.source_target_execution_id
                WHERE l.series_id = \(bind: seriesID) AND l.delivery_origin = 'alertDriven'
                """).first(decoding: Waterfall.self))
            #expect(joined.source == b.targetExecutionId)
            if failWinningStart {
                #expect(joined.targetStart == nil && joined.h3Complete == nil)
            } else {
                #expect(try #require(joined.targetStart) <= #require(joined.h3Complete))
                #expect(try #require(joined.h3Complete) <= joined.queued)
            }
            #expect(joined.queued <= joined.sendStart && joined.sendStart <= joined.resolved && joined.resolved <= joined.apns)
            try await DeviceInstallationModel.find(installationID, on: app.db)?.delete(on: app.db)
        }
    }

    @Test("ingest handoff supplies the target queue boundary preserved by execution")
    func targetQueueHandoffTiming() async throws {
        try await withWorkerApp { app in
            let seriesID = UUID()
            let revisionUrn = "urn:oid:target-handoff-\(UUID())"
            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(revisionUrn: revisionUrn, seriesId: seriesID,
                payload: .init(seriesId: seriesID, revisionUrn: revisionUrn, geometry: makePolygonGeometry(), reason: .new), created: .distantPast)
                .create(on: app.db)
            let context = makeQueueContext(app: app)
            _ = try await IngestNWSAlertsJob().dispatchPendingTargetJobs(context: context, limit: 1)
            let payload = try #require(app.queues.test.all(TargetEventRevisionJob.self).first { $0.seriesId == seriesID })
            let queuedAt = try #require(payload.queuedAt)
            try await TargetEventRevisionJob().dequeue(context, payload)
            let timing = try await loadTiming(revisionUrn, on: app.db)
            #expect(abs(try #require(timing.queuedAt).timeIntervalSince(queuedAt)) < 0.000_001)
            #expect(timing.startedAt >= queuedAt)
        }
    }

    @Test("target timing storage failures preserve coverage and notification dispatch", arguments: ["INSERT", "UPDATE"])
    func targetTimingWriteFailure(operation: String) async throws {
        try await withWorkerApp { app in
            let seriesID = UUID()
            let revisionUrn = "urn:oid:target-timing-failure-\(UUID())"
            let payload = TargetEventRevisionPayload(seriesId: seriesID, revisionUrn: revisionUrn,
                geometry: makePolygonGeometry(), reason: .new)
            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(revisionUrn: revisionUrn, seriesId: seriesID, payload: payload).create(on: app.db)
            let job = TargetEventRevisionJob()
            try await withPipelineTimingWriteFailure(table: "target_pipeline_timings", operation: operation, seriesID: seriesID, on: app.db) {
                try await job.dequeue(makeQueueContext(app: app), payload)
            }
            #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.seriesId == seriesID }.count == 1)
            if operation == "UPDATE" {
                let timing = try await loadTiming(revisionUrn, on: app.db)
                #expect(timing.completedAt == nil)
                try await job.dequeue(makeQueueContext(app: app), payload)
                #expect(try await loadTiming(revisionUrn, on: app.db) == timing)
            } else {
                try await job.dequeue(makeQueueContext(app: app), payload)
                let sql = try #require(app.db as? any SQLDatabase)
                let row = try await sql.raw("SELECT revision_urn FROM target_pipeline_timings WHERE revision_urn = \(bind: revisionUrn)").first()
                #expect(row == nil)
            }
        }
    }

    @Test("unsupported geometry enqueues and drains ugc fallback without draining h3")
    func unsupportedGeometryUsesUGCFallbackDrainOnly() async throws {
        try await withWorkerApp { app in
            let now = Date()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-unsupported-geometry-\(UUID().uuidString.lowercased())"
            let payload = TargetEventRevisionPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                geometry: .point(lon: -104.9903, lat: 39.7392),
                reason: .new
            )

            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(
                revisionUrn: revisionUrn,
                seriesId: seriesID,
                payload: payload
            ).create(on: app.db)

            try await ArcusNotificationOutboxModel(
                series: seriesID,
                revisionUrn: revisionUrn,
                mode: NotificationTargetMode.h3.rawValue,
                reason: NotificationReason.new.rawValue,
                state: "ready",
                attempts: 0,
                availableAt: now
            ).create(on: app.db)

            try await TargetEventRevisionJob().dequeue(makeQueueContext(app: app), payload)

            let targetDispatchRow = try await ArcusTargetDispatchOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .first()
            #expect(try await loadTiming(revisionUrn, on: app.db).completedAt == nil)
            #expect(targetDispatchRow?.result == "unsupported_geometry")
            #expect(targetDispatchRow?.completed != nil)

            let ugcRows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.ugc.rawValue)
                .all()
            #expect(ugcRows.count == 1)
            #expect(ugcRows.first?.state == "done")
            #expect(ugcRows.first?.attempts == 1)

            let h3Rows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.h3.rawValue)
                .all()
            #expect(h3Rows.count == 1)
            #expect(h3Rows.first?.state == "ready")
            #expect(h3Rows.first?.attempts == 0)
        }
    }

    @Test("precomputed supported coverage is persisted unchanged")
    func precomputedSupportedCoverageIsPersistedUnchanged() async throws {
        try await withWorkerApp { app in
            let now = Date()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-precomputed-coverage-\(UUID().uuidString.lowercased())"
            let geometry = makePolygonGeometry()
            let coverage = H3Coverage(
                cells: [617_700_169_958_293_503, -617_700_170_495_164_415],
                h3Hash: "injected-h3-hash",
                geometryHash: "injected-geometry-hash",
                resolution: 7
            )
            let payload = TargetEventRevisionPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                geometry: geometry,
                reason: .new,
                queuedAt: Date(timeIntervalSince1970: 1_000)
            )

            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(
                revisionUrn: revisionUrn,
                seriesId: seriesID,
                payload: payload
            ).create(on: app.db)

            let job = TargetEventRevisionJob(buildCoverage: { _ in .supported(coverage) })
            try await job.dequeue(makeQueueContext(app: app), payload)

            let geolocation = try await ArcusGeolocationModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .first()
            #expect(geolocation?.h3Cells == coverage.cells)
            #expect(geolocation?.h3Resolution == coverage.resolution)
            #expect(geolocation?.geometryHash == coverage.geometryHash)
            #expect(geolocation?.h3Hash == coverage.h3Hash)
            let timing = try await loadTiming(revisionUrn, on: app.db)
            let intent = try #require(try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn == revisionUrn).first())
            #expect(try #require(timing.completedAt) <= #require(intent.created))
            #expect(timing.queuedAt == payload.queuedAt)
            #expect(try #require(timing.completedAt) >= timing.startedAt)
            try await job.dequeue(makeQueueContext(app: app), payload)
            #expect(try await loadTiming(revisionUrn, on: app.db) == timing)

        }
    }

    @Test("precomputed cover failure uses ugc without h3 persistence")
    func precomputedCoverFailureUsesUGCWithoutH3Persistence() async throws {
        try await withWorkerApp { app in
            let now = Date()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-cover-failure-\(UUID().uuidString.lowercased())"
            let payload = TargetEventRevisionPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                geometry: makePolygonGeometry(),
                reason: .new
            )

            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(
                revisionUrn: revisionUrn,
                seriesId: seriesID,
                payload: payload
            ).create(on: app.db)

            let job = TargetEventRevisionJob(
                buildCoverage: { _ in .coverFailure(errorDescription: "injected cover failure") }
            )
            try await job.dequeue(makeQueueContext(app: app), payload)

            let targetDispatchRow = try await ArcusTargetDispatchOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .first()
            #expect(try await loadTiming(revisionUrn, on: app.db).completedAt == nil)
            #expect(targetDispatchRow?.result == "unsupported_geometry")
            #expect(targetDispatchRow?.completed != nil)

            let geolocation = try await ArcusGeolocationModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .first()
            #expect(geolocation == nil)

            let ugcRows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.ugc.rawValue)
                .all()
            #expect(ugcRows.count == 1)
            #expect(ugcRows.first?.state == "done")
            #expect(ugcRows.first?.attempts == 1)

            let h3Rows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.h3.rawValue)
                .all()
            #expect(h3Rows.isEmpty)
        }
    }

    @Test("unchanged polygon geometry still enqueues h3 notification dispatch")
    func unchangedPolygonGeometryStillQueuesH3Notification() async throws {
        try await withWorkerApp { app in
            let now = Date()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-unchanged-geometry-\(UUID().uuidString.lowercased())"
            let geometry = makePolygonGeometry()
            let cover = try h3Cover(for: geometry)
            let payload = TargetEventRevisionPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                geometry: geometry,
                reason: .update
            )

            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now).create(on: app.db)
            try await ArcusGeolocationModel(
                series: seriesID,
                geometry: geometry,
                geometryHash: cover.geometryHash,
                h3Cells: cover.h3Cells,
                h3Resolution: 8,
                h3Hash: cover.h3Hash
            ).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(
                revisionUrn: revisionUrn,
                seriesId: seriesID,
                payload: payload
            ).create(on: app.db)

            try await TargetEventRevisionJob().dequeue(makeQueueContext(app: app), payload)

            let targetDispatchRow = try await ArcusTargetDispatchOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .first()
            #expect(targetDispatchRow?.result == "succeeded")
            #expect(targetDispatchRow?.completed != nil)

            let h3Rows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.h3.rawValue)
                .all()

            #expect(h3Rows.count == 1)
            #expect(h3Rows.first?.state == "done")
            #expect(h3Rows.first?.attempts == 1)
            #expect(h3Rows.first?.lastError == nil)
        }
    }

    @Test("redelivered same-geometry revision does not requeue completed h3 dispatch")
    func redeliveredSameGeometryRevisionDoesNotRequeueCompletedDispatch() async throws {
        try await withWorkerApp { app in
            let now = Date()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:test-redelivered-geometry-\(UUID().uuidString.lowercased())"
            let geometry = makePolygonGeometry()
            let cover = try h3Cover(for: geometry)
            let payload = TargetEventRevisionPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                geometry: geometry,
                reason: .update
            )

            try await makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now).create(on: app.db)
            try await ArcusGeolocationModel(
                series: seriesID,
                geometry: geometry,
                geometryHash: cover.geometryHash,
                h3Cells: cover.h3Cells,
                h3Resolution: 8,
                h3Hash: cover.h3Hash
            ).create(on: app.db)
            try await ArcusTargetDispatchOutboxModel(
                revisionUrn: revisionUrn,
                seriesId: seriesID,
                payload: payload,
                attemptCount: 1,
                completed: now,
                result: "succeeded"
            ).create(on: app.db)
            try await ArcusNotificationOutboxModel(
                series: seriesID,
                revisionUrn: revisionUrn,
                mode: NotificationTargetMode.h3.rawValue,
                reason: NotificationReason.update.rawValue,
                state: "done",
                attempts: 1,
                availableAt: now
            ).create(on: app.db)

            try await TargetEventRevisionJob().dequeue(makeQueueContext(app: app), payload)

            let targetDispatchRow = try await ArcusTargetDispatchOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .first()
            #expect(targetDispatchRow?.result == "succeeded")
            #expect(targetDispatchRow?.completed != nil)

            let h3Rows = try await ArcusNotificationOutboxModel.query(on: app.db)
                .filter(\.$revisionUrn, .equal, revisionUrn)
                .filter(\.$mode, .equal, NotificationTargetMode.h3.rawValue)
                .all()

            #expect(h3Rows.count == 1)
            #expect(h3Rows.first?.state == "done")
            #expect(h3Rows.first?.attempts == 1)
            #expect(h3Rows.first?.lastError == nil)
        }
    }
}

private actor PipelineTimingSender: NotificationSender {
    private(set) var count = 0
    func sendNotification(app: Application, with: AlertDetails, hotAlertPayload: HotAlertAPNsPayload,
                          to: String, environment: APNsEnvironment) async throws { count += 1 }
}
