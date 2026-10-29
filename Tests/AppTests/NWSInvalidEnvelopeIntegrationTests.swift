@testable import App
import Fluent
import Foundation
import Logging
import Queues
import Testing
import Vapor
import XCTQueues

@Suite("NWS invalid envelope integration", .serialized, .sharedDatabase)
struct NWSInvalidEnvelopeIntegrationTests {
    @Test func invalidEnvelopesFailWithoutRenewingSuccessOrChangingAcceptedState() async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            app.queues.use(.test)
            let id = UUID()
            let label = "issue-384-\(id)"
            let now = Date()
            let series = ArcusSeriesModel(
                id: id, source: "nws", event: "Tornado Warning",
                sourceURL: "https://api.weather.gov/alerts/\(id)",
                currentRevisionUrn: "urn:oid:\(id)", currentRevisionSent: now,
                messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
                state: "active", lastSeenActive: now, severity: "severe",
                urgency: "immediate", certainty: "observed", ugcCodes: []
            )
            try await series.create(on: app.db)
            let context = QueueContext(queueName: ArcusQueueLane.ingest.queueName,
                configuration: app.queues.configuration, application: app,
                logger: app.logger, on: app.eventLoopGroup.any())
            let job = IngestNWSAlertsJob()
            let payload = IngestNWSAlertsPayload(runLabel: label)
            app.nwsIngestService = EnvelopeService(json: #"{"type":"FeatureCollection","features":[]}"#)
            try await job.dequeue(context, payload)
            let success = try #require(try await IngestSweepRunModel.query(on: app.db)
                .filter(\.$runLabel == label).filter(\.$status == "succeeded").first())

            for json in [#"{"type":"FeatureCollection"}"#,
                         #"{"type":"FeatureCollection","features":null}"#,
                         #"{"type":"upstream-error","title":"temporary failure"}"#] {
                app.nwsIngestService = EnvelopeService(json: json)
                await #expect(throws: (any Error).self) { try await job.dequeue(context, payload) }
            }
            let runs = try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == label).all()
            #expect(runs.filter { $0.status == "succeeded" }.count == 1)
            #expect(runs.filter { $0.status == "failed" }.count == 3)
            let retained = try #require(try await ArcusSeriesModel.find(id, on: app.db))
            #expect(retained.state == "active")
            #expect(retained.currentRevisionUrn == series.currentRevisionUrn)
            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: Date())
            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            #expect(snapshot.ingestFreshness.lastSuccessfulCompletedAt == success.completedAt)
            try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == label).delete()
            try await retained.delete(on: app.db)
        }
    }
}

private struct EnvelopeService: NWSIngestService {
    let json: String
    func ingestOnce(on application: Application, logger: Logger) async throws -> [ArcusEvent] {
        try JSONDecoder().decode(NwsEventDTO.self, from: Data(json.utf8)).toArcusEvents()
    }
}
