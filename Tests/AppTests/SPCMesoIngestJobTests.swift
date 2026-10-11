@testable import App
import ArcusCore
import Fluent
import Foundation
import Queues
import Testing
import Vapor

@Suite("SPC meso ingest job", .serialized)
struct SPCMesoIngestJobTests {
    @Test func fullIngestCyclePersistsCoverageAndRunFreshnessIdempotently() async throws {
        let app = try await Application.make(.testing)
        let productKey = "SPC-MD-2025-9876"
        let runLabel = "spc-meso-test-\(UUID().uuidString)"
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            app.queues.use(.test)
            let url = try #require(Bundle.module.url(
                forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"
            ))
            let xml = try String(contentsOf: url, encoding: .utf8)
                .replacingOccurrences(of: "0123", with: "9876")
            let product = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
            #expect(product.productID == productKey)
            app.spcMesoClient = StaticSPCMesoClient(products: [product])
            try await SPCMesoModel.query(on: app.db).filter(\.$productKey == productKey).delete()
            let notificationOutboxBefore = try await ArcusNotificationOutboxModel.query(on: app.db).count()
            let notificationLedgerBefore = try await NotificationLedgerModel.query(on: app.db).count()

            let context = QueueContext(
                queueName: ArcusQueueLane.ingest.queueName,
                configuration: app.queues.configuration,
                application: app,
                logger: app.logger,
                on: app.eventLoopGroup.any()
            )
            let job = IngestSPCMesoJob()
            let payload = IngestSPCMesoPayload(runLabel: runLabel)
            try await job.dequeue(context, payload)
            try await job.dequeue(context, payload)

            let rows = try await SPCMesoModel.query(on: app.db)
                .filter(\.$productKey == productKey)
                .all()
            let row = try #require(rows.first)
            #expect(rows.count == 1)
            let acceptedFingerprint = row.contentFingerprint
            let geolocation = try #require(try await SPCMesoGeolocationModel.query(on: app.db)
                .filter(\.$meso.$id == row.requireID())
                .first())
            #expect(geolocation.h3Resolution == 8)
            #expect(!geolocation.h3Cells.isEmpty && geolocation.h3Hash != nil)
            let runs = try await IngestSweepRunModel.query(on: app.db)
                .filter(\.$runLabel == runLabel)
                .all()
            #expect(runs.count == 2)
            #expect(runs.allSatisfy { $0.status == IngestSweepRunStatus.succeeded.rawValue })
            #expect(runs.allSatisfy { $0.eventCount == 1 && $0.errorMessage == nil })
            #expect(!app.queues.test.contains(NotificationSendJob.self))
            #expect(try await ArcusNotificationOutboxModel.query(on: app.db).count() == notificationOutboxBefore)
            #expect(try await NotificationLedgerModel.query(on: app.db).count() == notificationLedgerBefore)

            app.spcMesoClient = StaticSPCMesoClient(failure: .fetch)
            await #expect(throws: SPCMesoError.upstreamStatus(503)) {
                try await job.dequeue(context, payload)
            }
            app.spcMesoClient = StaticSPCMesoClient(failure: .parse)
            await #expect(throws: SPCMesoError.malformedDiscussion("injected malformed MD")) {
                try await job.dequeue(context, payload)
            }

            let changedXML = xml.replacingOccurrences(of: "Severe storms possible.", with: "Changed discussion content.")
            let changedProduct = try #require(SPCMesoParser.parse(Data(changedXML.utf8)).first)
            app.spcMesoClient = StaticSPCMesoClient(products: [product, changedProduct])
            await #expect(throws: SPCMesoError.malformedDiscussion(productKey)) {
                try await job.dequeue(context, payload)
            }

            let invalidGeometryXML = xml.replacingOccurrences(
                of: "LAT...LON 39000288 40000200 38500100 39000288",
                with: "LAT...LON 39000300 41000100 41000300 39000000 39000300"
            )
            let invalidGeometryProduct = try #require(SPCMesoParser.parse(Data(invalidGeometryXML.utf8)).first)
            app.spcMesoClient = StaticSPCMesoClient(products: [invalidGeometryProduct])
            await #expect(throws: Abort.self) {
                try await job.dequeue(context, payload)
            }

            app.spcMesoClient = StaticSPCMesoClient(products: [product])
            let persistenceFailureJob = IngestSPCMesoJob(persist: { _, _, _ in
                throw TestPersistenceFailure.injected
            })
            await #expect(throws: TestPersistenceFailure.self) {
                try await persistenceFailureJob.dequeue(context, payload)
            }

            let failedRuns = try await IngestSweepRunModel.query(on: app.db)
                .filter(\.$runLabel == runLabel)
                .filter(\.$status == IngestSweepRunStatus.failed.rawValue)
                .all()
            #expect(failedRuns.count == 5)
            for stage in ["fetch", "parse_reject", "persistence", "h3"] {
                #expect(failedRuns.contains { $0.errorMessage?.contains("stage=\(stage)") == true })
            }
            let retained = try #require(try await SPCMesoModel.query(on: app.db)
                .filter(\.$productKey == productKey)
                .first())
            #expect(retained.contentFingerprint == acceptedFingerprint)
            #expect(!app.queues.test.contains(NotificationSendJob.self))

            try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == row.requireID()).delete()
            try await SPCMesoModel.query(on: app.db).filter(\.$productKey == productKey).delete()
            try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == runLabel).delete()
        } catch {
            try? await Self.cleanup(app: app, productKey: productKey, runLabel: runLabel)
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private static func cleanup(app: Application, productKey: String, runLabel: String) async throws {
        if let row = try await SPCMesoModel.query(on: app.db).filter(\.$productKey == productKey).first(),
           let id = row.id {
            try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == id).delete()
            try await row.delete(on: app.db)
        }
        try await IngestSweepRunModel.query(on: app.db).filter(\.$runLabel == runLabel).delete()
    }
}

private struct StaticSPCMesoClient: SPCMesoClient {
    enum Failure: Sendable { case fetch, parse }

    let products: [MesoscaleDiscussionPayload]
    let failure: Failure?

    init(products: [MesoscaleDiscussionPayload] = [], failure: Failure? = nil) {
        self.products = products
        self.failure = failure
    }

    func fetchDiscussions() async throws -> [MesoscaleDiscussionPayload] {
        switch failure {
        case .fetch: throw SPCMesoError.upstreamStatus(503)
        case .parse: throw SPCMesoError.malformedDiscussion("injected malformed MD")
        case nil: return products
        }
    }
}

private enum TestPersistenceFailure: Error, Sendable {
    case injected
}
