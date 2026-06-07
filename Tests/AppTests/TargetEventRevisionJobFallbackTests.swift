@testable import App
import Foundation
import Queues
import SwiftyH3
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
            try await test(app)
        } catch {
            Issue.record("Worker app bootstrap/test failed: \(String(reflecting: error))")
            try? await app.asyncShutdown()
            throw error
        }

        try await app.asyncShutdown()
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
        let geometryHash = try StableContentHasher.sha256Hex(of: geometry, dateEncodingStrategy: .deferredToDate)

        switch geometry {
        case .point:
            throw Abort(.badRequest, reason: "Test fixture requires polygon geometry.")
        case .polygon(let rings):
            let cells = try h3Cells(for: rings)
            let sorted = Array(Set(cells)).sorted()
            return (geometryHash, sorted, h3Hash(for: sorted))
        case .multiPolygon:
            throw Abort(.badRequest, reason: "Test fixture requires polygon geometry.")
        }
    }

    private func h3Cells(for rings: [[GeoShape.GeoCoordinate]]) throws -> [Int64] {
        guard let boundaryRing = rings.first, !boundaryRing.isEmpty else {
            throw SwiftyH3Error.invalidInput
        }

        let boundary: H3Loop = boundaryRing.map { coordinate in
            H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
        }

        let polygon = H3Polygon(boundary, holes: [])
        let resolution = H3Cell.Resolution(rawValue: Int32(8)) ?? .res8
        let cells = try polygon.cells(at: resolution)
        return cells.map { Int64(bitPattern: $0.id) }
    }

    private func h3Hash(for sortedCells: [Int64]) -> String {
        var data = Data(capacity: sortedCells.count * MemoryLayout<UInt64>.size)
        for value in sortedCells {
            var bigEndian = UInt64(bitPattern: value).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return StableContentHasher.sha256Hex(of: data)
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
            #expect(h3Rows.first?.state == "ready")
            #expect(h3Rows.first?.attempts == 0)
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
