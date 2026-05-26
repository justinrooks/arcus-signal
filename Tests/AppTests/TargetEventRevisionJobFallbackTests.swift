@testable import App
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
}
