@testable import App
import Fluent
import Foundation
import Queues
import Testing
import Vapor

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
                reason: .new
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
