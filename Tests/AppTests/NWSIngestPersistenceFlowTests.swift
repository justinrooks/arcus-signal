@testable import App
import Fluent
import ArcusCore
import APNSCore
import Foundation
import Queues
import SQLKit
import XCTQueues
import Testing
import Vapor

@Suite("NWS ingest persistence flow", .serialized, .sharedDatabase)
struct NWSIngestPersistenceFlowTests {
    private enum Rollback: Error {
        case forcedLateFailure
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeEvent(
        urn: String,
        references: [String] = [],
        sent: Date?,
        geometry: GeoShape?,
        sourceURL: String? = nil
    ) -> ArcusEvent {
        ArcusEvent(
            urn: urn,
            source: .nws,
            kind: "Tornado Warning",
            sourceURL: sourceURL ?? "https://api.weather.gov/alerts/\(urn)",
            vtec: nil,
            messageType: references.isEmpty ? .alert : .update,
            state: .active,
            references: references,
            sent: sent,
            effective: sent,
            onset: sent,
            expires: now.addingTimeInterval(3_600),
            ends: nil,
            lastSeenActive: now,
            severity: .severe,
            urgency: .immediate,
            certainty: .observed,
            geometry: geometry,
            ugcCodes: ["COC031"],
            title: "Tornado Warning",
            areaDesc: "Test County",
            rawRef: nil,
            category: "Met",
            event: "Tornado Warning",
            senderName: "NWS Test",
            headline: "Tornado Warning",
            description: "Storm text",
            instructions: "Take shelter now",
            response: "Shelter",
            status: "Actual",
            tornadoDetection: nil,
            tornadoDamageThreat: nil,
            maxWindGust: nil,
            maxHailSize: nil,
            windThreat: nil,
            hailThreat: nil,
            thunderstormDamageThreat: nil,
            flashFloodDetection: nil,
            flashFloodDamageThreat: nil
        )
    }

    private func polygon(offset: Double = 0) -> GeoShape {
        .polygon(rings: [[
            .init(lon: -104.99 + offset, lat: 39.73),
            .init(lon: -104.97 + offset, lat: 39.73),
            .init(lon: -104.98 + offset, lat: 39.75),
            .init(lon: -104.99 + offset, lat: 39.73)
        ]])
    }

    private func revisions(
        for urns: [String],
        on database: any Database
    ) async throws -> [ArcusEventRevisionModel] {
        try await ArcusEventRevisionModel.query(on: database)
            .filter(\.$revisionUrn ~~ urns)
            .all()
    }

    private func series(
        for sourceURLs: [String],
        on database: any Database
    ) async throws -> [ArcusSeriesModel] {
        try await ArcusSeriesModel.query(on: database)
            .filter(\.$sourceURL ~~ sourceURLs)
            .all()
    }

    private func targetOutboxes(
        for urns: [String],
        on database: any Database
    ) async throws -> [ArcusTargetDispatchOutboxModel] {
        try await ArcusTargetDispatchOutboxModel.query(on: database)
            .filter(\.$revisionUrn ~~ urns)
            .all()
    }

    private func notificationOutboxes(
        for urns: [String],
        on database: any Database
    ) async throws -> [ArcusNotificationOutboxModel] {
        try await ArcusNotificationOutboxModel.query(on: database)
            .filter(\.$revisionUrn ~~ urns)
            .all()
    }

    @Test("new polygon, point, and nil geometry persist exact dispatch intents")
    func newEventsPersistExpectedTargetingState() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let prefix = UUID().uuidString.lowercased()
                let polygonEvent = makeEvent(
                    urn: "urn:oid:\(prefix)-polygon",
                    sent: now,
                    geometry: polygon()
                )
                let pointEvent = makeEvent(
                    urn: "urn:oid:\(prefix)-point",
                    sent: now,
                    geometry: .point(lon: -104.99, lat: 39.73)
                )
                let nilEvent = makeEvent(
                    urn: "urn:oid:\(prefix)-nil",
                    sent: now,
                    geometry: nil
                )
                let events = [polygonEvent, pointEvent, nilEvent]
                let urns = events.map(\.id)

                let result = try await NWSIngestPersistence().persistArcusEvents(
                    events,
                    on: database,
                    asOf: now,
                    logger: app.logger
                )

                #expect(result.newSeriesCreated == 3)
                #expect(result.newRevisionsCreated == 3)
                #expect(result.targetOutboxQueued == 2)
                #expect(result.notificationOutboxQueued == 2)

                let storedRevisions = try await revisions(for: urns, on: database)
                let seriesIDsByUrn = Dictionary(
                    uniqueKeysWithValues: storedRevisions.map { ($0.revisionUrn, $0.$series.id) }
                )
                #expect(storedRevisions.count == 3)
                #expect(Set(seriesIDsByUrn.values).count == 3)

                let storedSeries = try await series(for: events.map(\.sourceURL), on: database)
                #expect(storedSeries.count == 3)
                for event in events {
                    let eventSeries = try #require(
                        storedSeries.first { $0.currentRevisionUrn == event.id }
                    )
                    #expect(eventSeries.id == seriesIDsByUrn[event.id])
                    #expect(eventSeries.currentRevisionSent == event.sent)
                    #expect(eventSeries.sourceURL == event.sourceURL)
                    #expect(eventSeries.state == EventState.active.rawValue)
                }

                let targetRows = try await targetOutboxes(for: urns, on: database)
                #expect(Set(targetRows.map(\.revisionUrn)) == [polygonEvent.id, pointEvent.id])
                for row in targetRows {
                    #expect(row.$series.id == seriesIDsByUrn[row.revisionUrn])
                    #expect(row.payload.seriesId == row.$series.id)
                    #expect(row.payload.revisionUrn == row.revisionUrn)
                    #expect(row.payload.reason == .new)
                    #expect(row.dispatched == nil)
                }
                #expect(targetRows.first { $0.revisionUrn == polygonEvent.id }?.payload.geometry == polygonEvent.geometry)
                #expect(targetRows.first { $0.revisionUrn == pointEvent.id }?.payload.geometry == pointEvent.geometry)

                let notificationRows = try await notificationOutboxes(for: urns, on: database)
                #expect(Set(notificationRows.map(\.revisionUrn)) == [pointEvent.id, nilEvent.id])
                for row in notificationRows {
                    #expect(row.$series.id == seriesIDsByUrn[row.revisionUrn])
                    #expect(row.mode == NotificationTargetMode.ugc.rawValue)
                    #expect(row.reason == NotificationReason.new.rawValue)
                    #expect(row.state == "ready")
                    #expect(row.attempts == 0)
                }
            }
        }
    }

    @Test("duplicate revision is a complete persistence no-op")
    func duplicateRevisionIsNoOp() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let prefix = UUID().uuidString.lowercased()
                let event = makeEvent(
                    urn: "urn:oid:\(prefix)-duplicate",
                    sent: now,
                    geometry: .point(lon: -104.99, lat: 39.73)
                )

                let first = try await NWSIngestPersistence().persistArcusEvents(
                    [event],
                    on: database,
                    asOf: now,
                    logger: app.logger
                )
                let duplicate = try await NWSIngestPersistence().persistArcusEvents(
                    [event],
                    on: database,
                    asOf: now,
                    logger: app.logger
                )

                #expect(first.newSeriesCreated == 1)
                #expect(first.newRevisionsCreated == 1)
                #expect(first.targetOutboxQueued == 1)
                #expect(first.notificationOutboxQueued == 1)
                #expect(duplicate.newSeriesCreated == 0)
                #expect(duplicate.newRevisionsCreated == 0)
                #expect(duplicate.targetOutboxQueued == 0)
                #expect(duplicate.notificationOutboxQueued == 0)
                let storedSeries = try await series(for: [event.sourceURL], on: database)
                #expect(storedSeries.count == 1)
                #expect(storedSeries.first?.currentRevisionUrn == event.id)
                #expect(storedSeries.first?.currentRevisionSent == event.sent)
                #expect(try await revisions(for: [event.id], on: database).count == 1)
                #expect(try await targetOutboxes(for: [event.id], on: database).count == 1)
                #expect(try await notificationOutboxes(for: [event.id], on: database).count == 1)
            }
        }
    }

    @Test("newer revision advances snapshot while older revision remains lineage-only")
    func revisionOrderingPreservesNewestSnapshot() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let prefix = UUID().uuidString.lowercased()
                let base = makeEvent(
                    urn: "urn:oid:\(prefix)-base",
                    sent: now,
                    geometry: polygon()
                )
                let newer = makeEvent(
                    urn: "urn:oid:\(prefix)-newer",
                    references: [base.id],
                    sent: now.addingTimeInterval(120),
                    geometry: polygon(offset: 0.1)
                )
                let older = makeEvent(
                    urn: "urn:oid:\(prefix)-older",
                    references: [newer.id],
                    sent: now.addingTimeInterval(60),
                    geometry: polygon(offset: 0.2)
                )
                let urns = [base.id, newer.id, older.id]

                let result = try await NWSIngestPersistence().persistArcusEvents(
                    [base, newer, older],
                    on: database,
                    asOf: now,
                    logger: app.logger
                )

                #expect(result.newSeriesCreated == 1)
                #expect(result.newRevisionsCreated == 3)
                #expect(result.targetOutboxQueued == 2)
                #expect(result.notificationOutboxQueued == 0)

                let storedRevisions = try await revisions(for: urns, on: database)
                let seriesID = try #require(storedRevisions.first?.$series.id)
                #expect(storedRevisions.count == 3)
                #expect(Set(storedRevisions.map(\.$series.id)) == [seriesID])

                let series = try #require(try await ArcusSeriesModel.find(seriesID, on: database))
                #expect(series.currentRevisionUrn == newer.id)
                #expect(series.currentRevisionSent == newer.sent)
                #expect(series.sourceURL == newer.sourceURL)

                let targetRows = try await targetOutboxes(for: urns, on: database)
                #expect(Set(targetRows.map(\.revisionUrn)) == [base.id, newer.id])
                #expect(targetRows.first { $0.revisionUrn == base.id }?.payload.reason == .new)
                #expect(targetRows.first { $0.revisionUrn == newer.id }?.payload.reason == .update)
                #expect(targetRows.allSatisfy { $0.$series.id == seriesID && $0.payload.seriesId == seriesID })
                #expect(try await notificationOutboxes(for: urns, on: database).isEmpty)
            }
        }
    }

    @Test("referenced series merge chooses newest deterministic winner and reconciles lineage")
    func referencedSeriesMergeReconcilesDatabaseState() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            try await withRollbackTransaction(on: app) { database in
                let prefix = UUID().uuidString.lowercased()
                let older = makeEvent(
                    urn: "urn:oid:\(prefix)-merge-older",
                    sent: now,
                    geometry: polygon()
                )
                let tiedNewerA = makeEvent(
                    urn: "urn:oid:\(prefix)-merge-newer-a",
                    sent: now.addingTimeInterval(120),
                    geometry: polygon(offset: 0.1)
                )
                let tiedNewerB = makeEvent(
                    urn: "urn:oid:\(prefix)-merge-newer-b",
                    sent: now.addingTimeInterval(120),
                    geometry: polygon(offset: 0.2)
                )
                let bases = [older, tiedNewerA, tiedNewerB]
                _ = try await NWSIngestPersistence().persistArcusEvents(
                    bases,
                    on: database,
                    asOf: now,
                    logger: app.logger
                )

                let baseRevisions = try await revisions(for: bases.map(\.id), on: database)
                let baseSeriesIDs = Dictionary(
                    uniqueKeysWithValues: baseRevisions.map { ($0.revisionUrn, $0.$series.id) }
                )
                let allBaseSeriesIDs = try bases.map {
                    try #require(baseSeriesIDs[$0.id])
                }
                let timestampLoserSeriesID = try #require(
                    allBaseSeriesIDs.min { $0.uuidString < $1.uuidString }
                )
                let tiedSeriesIDs = allBaseSeriesIDs.filter { $0 != timestampLoserSeriesID }
                let winnerSeriesID = try #require(
                    tiedSeriesIDs.min { $0.uuidString < $1.uuidString }
                )
                let loserSeriesIDs = Set(
                    [timestampLoserSeriesID] + tiedSeriesIDs.filter { $0 != winnerSeriesID }
                )

                for seriesID in allBaseSeriesIDs {
                    let series = try #require(
                        try await ArcusSeriesModel.find(seriesID, on: database)
                    )
                    let rankingTimestamp = seriesID == timestampLoserSeriesID
                        ? now
                        : now.addingTimeInterval(120)
                    series.currentRevisionSent = rankingTimestamp
                    series.sent = rankingTimestamp
                    try await series.update(on: database)
                }

                for (index, seriesID) in ([winnerSeriesID] + Array(loserSeriesIDs)).enumerated() {
                    let geolocation = ArcusGeolocationModel(
                        series: seriesID,
                        geometry: .point(lon: -104.99 + Double(index), lat: 39.73),
                        geometryHash: "geometry-\(index)",
                        h3Cells: [Int64(index + 1)],
                        h3Resolution: 8,
                        h3Hash: "h3-\(index)"
                    )
                    try await geolocation.create(on: database)
                }

                let merge = makeEvent(
                    urn: "urn:oid:\(prefix)-merge",
                    references: bases.map(\.id),
                    sent: now.addingTimeInterval(240),
                    geometry: polygon(offset: 0.3)
                )
                let mergeResult = try await NWSIngestPersistence().persistArcusEvents(
                    [merge],
                    on: database,
                    asOf: now,
                    logger: app.logger
                )

                #expect(mergeResult.newSeriesCreated == 0)
                #expect(mergeResult.newRevisionsCreated == 1)
                #expect(mergeResult.targetOutboxQueued == 1)
                #expect(mergeResult.notificationOutboxQueued == 0)

                let allUrns = bases.map(\.id) + [merge.id]
                let storedRevisions = try await revisions(for: allUrns, on: database)
                #expect(storedRevisions.count == 4)
                #expect(Set(storedRevisions.map(\.$series.id)) == [winnerSeriesID])

                let winner = try #require(try await ArcusSeriesModel.find(winnerSeriesID, on: database))
                #expect(winner.currentRevisionUrn == merge.id)
                #expect(winner.currentRevisionSent == merge.sent)
                #expect(winner.state == EventState.active.rawValue)
                for loserSeriesID in loserSeriesIDs {
                    let loser = try #require(try await ArcusSeriesModel.find(loserSeriesID, on: database))
                    #expect(loser.state == EventState.expired.rawValue)
                    #expect(loser.lastSeenActive == now)
                }

                let targetRows = try await targetOutboxes(for: allUrns, on: database)
                #expect(targetRows.count == 4)
                #expect(Set(targetRows.map(\.revisionUrn)) == Set(allUrns))
                #expect(targetRows.allSatisfy {
                    $0.$series.id == winnerSeriesID
                        && $0.payload.seriesId == winnerSeriesID
                        && $0.dispatched == nil
                })
                #expect(targetRows.first { $0.revisionUrn == merge.id }?.payload.reason == .update)
                #expect(targetRows.filter { $0.revisionUrn != merge.id }.allSatisfy { $0.payload.reason == .new })

                let geolocations = try await ArcusGeolocationModel.query(on: database)
                    .filter(\.$series.$id ~~ ([winnerSeriesID] + Array(loserSeriesIDs)))
                    .all()
                #expect(geolocations.isEmpty)
                #expect(try await notificationOutboxes(for: allUrns, on: database).isEmpty)
            }
        }
    }

    private func withCoverageApp(test: (Application, String) async throws -> Void) async throws {
        let databaseName = Environment.get("DATABASE_URL")
            .flatMap { URLComponents(string: $0)?.path.split(separator: "/").last.map(String.init) }
            ?? Environment.get("DATABASE_NAME") ?? ""
        guard databaseName.range(of: #"^arcus_issue[0-9]+_(test|validation)(_|$)"#, options: .regularExpression) != nil,
              !databaseName.contains("/") else {
            throw Abort(.internalServerError, reason: "Coverage tests require an explicit issue-scoped test database.")
        }
        let sourceURL = "https://api.weather.gov/alerts/issue354-\(UUID())"
        try await withIntegrationTestApplication(setup: .configured(mode: .worker, migrate: true)) { app in
            app.queues.use(.test)
            do {
                try await test(app, sourceURL)
            } catch {
                try await ArcusSeriesModel.query(on: app.db).filter(\.$sourceURL == sourceURL).delete()
                try await DeviceInstallationModel.query(on: app.db).filter(\.$apnsDeviceToken == sourceURL).delete()
                throw error
            }
            try await ArcusSeriesModel.query(on: app.db).filter(\.$sourceURL == sourceURL).delete()
            try await DeviceInstallationModel.query(on: app.db).filter(\.$apnsDeviceToken == sourceURL).delete()
        }
    }

    private func context(_ app: Application) -> QueueContext {
        .init(queueName: .init(string: "issue354"), configuration: app.queues.configuration,
              application: app, logger: app.logger, on: app.eventLoopGroup.any())
    }

    private func accept(_ event: ArcusEvent, on app: Application) async throws {
        _ = try await app.db.transaction {
            try await NWSIngestPersistence().persistArcusEvents([event], on: $0, asOf: now, logger: app.logger)
        }
    }

    @Test("snapshot advancement removes old coverage before new targeting", arguments: ["narrow", "expand", "nil", "point"])
    func revisionCoverageCoherence(transition: String) async throws {
        try await withCoverageApp { app, sourceURL in
            let a = makeEvent(urn: "urn:oid:\(UUID())", sent: now, geometry: polygon(), sourceURL: sourceURL)
            let geometry: GeoShape? = transition == "nil" ? nil
                : transition == "point" ? .point(lon: -105, lat: 40) : polygon(offset: 0.1)
            let b = makeEvent(urn: "urn:oid:\(UUID())", references: [a.id], sent: now.addingTimeInterval(60),
                              geometry: geometry, sourceURL: sourceURL)
            try await accept(a, on: app)
            let seriesID = try #require(try await ArcusEventRevisionModel.query(on: app.db)
                .filter(\.$revisionUrn == a.id).first()).$series.id
            let installationID = UUID()
            try await DeviceInstallationModel(installationId: installationID, apnsDeviceToken: sourceURL,
                apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26", appVersion: "1", buildNumber: "1",
                locationAuth: .always).create(on: app.db)
            try await DevicePresenceModel(installationId: installationID, capturedAt: .now,
                locationAgeSeconds: 0, horizontalAccuracyMeters: 10, cellScheme: .h3, h3Cell: 202, h3Resolution: 8,
                county: nil, zone: nil, fireZone: nil, source: .unknown, countyLabel: nil, fireZoneLabel: nil).create(on: app.db)
            let candidates = NotificationCandidateStore()
            let cellsA: [Int64] = transition == "expand" ? [101] : [101, 202]
            let cellsB: [Int64] = transition == "expand" ? [101, 202] : [101]
            let jobA = TargetEventRevisionJob(buildCoverage: { _ in
                .supported(.init(cells: cellsA, h3Hash: "A", geometryHash: "A", resolution: 8))
            })
            let payloadA = TargetEventRevisionPayload(seriesId: seriesID, revisionUrn: a.id,
                geometry: polygon(), reason: .new)
            try await jobA.dequeue(context(app), payloadA)
            try await accept(b, on: app)
            let sql = try #require(app.db as? any SQLDatabase)
            let intermediate = try await loadAlertSeries(sql: sql, ugcCodes: ["COC031"], h3: nil, evaluatedAt: now)
            let row = try #require(intermediate.first { $0.id == seriesID })
            #expect(row.currentRevisionUrn == b.id)
            #expect(row.geometry == nil && row.h3Cells.isEmpty)
            #expect(try await loadAlertSeries(sql: sql, ugcCodes: [], h3: 202, evaluatedAt: now)
                .allSatisfy { $0.id != seriesID })
            #expect(try await candidates.loadMatchingActiveAlerts(for: installationID, evaluatedAt: now, on: app.db)
                .allSatisfy { $0.seriesId != seriesID })
            // An old job finishing while B has no coverage must not resurrect A.
            try await jobA.dequeue(context(app), payloadA)
            #expect(try await ArcusGeolocationModel.query(on: app.db).filter(\.$series.$id == seriesID).count() == 0)
            if let geometry {
                let jobB = TargetEventRevisionJob(buildCoverage: { _ in
                    transition == "point" ? .unsupportedPoint
                        : .supported(.init(cells: cellsB, h3Hash: "B", geometryHash: "B", resolution: 8))
                })
                try await jobB.dequeue(context(app), .init(seriesId: seriesID, revisionUrn: b.id,
                    geometry: geometry, reason: .update))
            }
            try await jobA.dequeue(context(app), payloadA)
            let final = try #require(try await loadAlertSeries(sql: sql, ugcCodes: ["COC031"], h3: nil, evaluatedAt: now)
                .first { $0.id == seriesID })
            let polygonB = transition == "narrow" || transition == "expand"
            #expect(final.currentRevisionUrn == b.id)
            #expect(final.h3Cells == (polygonB ? cellsB : []))
            #expect(final.geometry == (polygonB ? geometry : nil))
            let intents = try await notificationOutboxes(for: [b.id], on: app.db)
            #expect(intents.count == 1)
            #expect(intents.first?.mode == (polygonB ? "h3" : "ugc"))
            let presenceMatches = try await candidates.loadMatchingActiveAlerts(for: installationID, evaluatedAt: now, on: app.db)
            #expect(presenceMatches.contains { $0.seriesId == seriesID } == (transition == "expand"))
            let eventMatches = try await candidates.loadH3Candidates(cells: final.h3Cells,
                capturedAtOrAfter: Date().addingTimeInterval(-60), installationId: installationID, on: app.db)
            #expect(eventMatches.contains { $0.id == installationID } == (transition == "expand"))
        }
    }

    @Test("send rejects advancement between content and coverage reads")
    func sendRejectsMixedRevisionReads() async throws {
        try await withCoverageApp { app, sourceURL in
            let a = makeEvent(urn: "urn:oid:\(UUID())", sent: now, geometry: polygon(), sourceURL: sourceURL)
            let b = makeEvent(urn: "urn:oid:\(UUID())", references: [a.id], sent: now.addingTimeInterval(60),
                              geometry: polygon(offset: 0.1), sourceURL: sourceURL)
            try await accept(a, on: app)
            let id = try #require(try await ArcusEventRevisionModel.query(on: app.db)
                .filter(\.$revisionUrn == a.id).first()).$series.id
            let installationID = UUID()
            try await DeviceInstallationModel(installationId: installationID, apnsDeviceToken: sourceURL,
                apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26", appVersion: "1", buildNumber: "1",
                locationAuth: .always).create(on: app.db)
            try await DevicePresenceModel(installationId: installationID, capturedAt: .now,
                locationAgeSeconds: 0, horizontalAccuracyMeters: 10, cellScheme: .h3, h3Cell: 202, h3Resolution: 8,
                county: nil, zone: nil, fireZone: nil, source: .unknown, countyLabel: nil, fireZoneLabel: nil).create(on: app.db)
            let sender = CoverageRaceSender()
            let job = NotificationSendJob(sender: sender, beforeCoverageRead: {
                try await accept(b, on: app)
                let target = TargetEventRevisionJob(buildCoverage: { _ in
                    .supported(.init(cells: [202], h3Hash: "B", geometryHash: "B", resolution: 8))
                })
                try await target.dequeue(context(app), .init(seriesId: id, revisionUrn: b.id,
                    geometry: polygon(offset: 0.1), reason: .update))
            })
            try await job.dequeue(context(app), .init(seriesId: id, revisionUrn: a.id, mode: .h3, reason: .new))
            #expect(await sender.count == 0)
            let sql = try #require(app.db as? any SQLDatabase)
            struct Count: Decodable { let count: Int }
            let claims = try #require(try await sql.raw("SELECT COUNT(*)::int AS count FROM notification_ledger WHERE series_id = \(bind: id)").first(decoding: Count.self))
            #expect(claims.count == 0)
            let staleAttempts = try #require(try await sql.raw("""
                SELECT COUNT(*)::int AS count FROM notification_send_attempts
                WHERE series_id = \(bind: id) AND no_op_reason = 'stale_revision_mismatch'
                """).first(decoding: Count.self))
            #expect(staleAttempts.count == 1)
        }
    }

    @Test("non-advancing merge never borrows losing coverage")
    func olderMergeDoesNotBorrowCoverage() async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            try await withRollbackTransaction(on: app) { database in
                let winner = makeEvent(urn: "urn:oid:\(UUID())", sent: now.addingTimeInterval(120), geometry: nil)
                let loser = makeEvent(urn: "urn:oid:\(UUID())", sent: now, geometry: polygon())
                _ = try await NWSIngestPersistence().persistArcusEvents([winner, loser], on: database, asOf: now, logger: app.logger)
                let rows = try await revisions(for: [winner.id, loser.id], on: database)
                let winnerID = try #require(rows.first { $0.revisionUrn == winner.id }).$series.id
                let loserID = try #require(rows.first { $0.revisionUrn == loser.id }).$series.id
                try await ArcusGeolocationModel(series: loserID, geometry: polygon(), geometryHash: "loser",
                    h3Cells: [101], h3Resolution: 8, h3Hash: "loser").create(on: database)
                let merge = makeEvent(urn: "urn:oid:\(UUID())", references: [winner.id, loser.id],
                                      sent: now.addingTimeInterval(60), geometry: polygon())
                _ = try await NWSIngestPersistence().persistArcusEvents([merge], on: database, asOf: now, logger: app.logger)
                #expect(try await ArcusSeriesModel.find(winnerID, on: database)?.currentRevisionUrn == winner.id)
                #expect(try await ArcusGeolocationModel.query(on: database)
                    .filter(\.$series.$id ~~ [winnerID, loserID]).count() == 0)
            }
        }
    }

    @Test("target validation holds the series lock through its coverage write")
    func targetAcceptanceSerializesWithIngest() async throws {
        try await withCoverageApp { app, sourceURL in
            let a = makeEvent(urn: "urn:oid:\(UUID())", sent: now, geometry: polygon(), sourceURL: sourceURL)
            let b = makeEvent(urn: "urn:oid:\(UUID())", references: [a.id], sent: now.addingTimeInterval(60),
                              geometry: nil, sourceURL: sourceURL)
            try await accept(a, on: app)
            let id = try #require(try await ArcusEventRevisionModel.query(on: app.db)
                .filter(\.$revisionUrn == a.id).first()).$series.id
            let entered = AsyncStream<Void>.makeStream()
            let release = AsyncStream<Void>.makeStream()
            let job = TargetEventRevisionJob(buildCoverage: { _ in
                .supported(.init(cells: [101], h3Hash: "A", geometryHash: "A", resolution: 8))
            }, beforeCoverageWrite: {
                entered.continuation.yield(())
                for await _ in release.stream { break }
            })
            let target = Task {
                defer { entered.continuation.finish() }
                try await job.dequeue(context(app), .init(seriesId: id,
                    revisionUrn: a.id, geometry: polygon(), reason: .new))
            }
            defer { release.continuation.yield(()); release.continuation.finish() }
            var iterator = entered.stream.makeAsyncIterator()
            _ = try #require(await iterator.next())
            do {
                _ = try await app.db.transaction { database in
                    let sql = try #require(database as? any SQLDatabase)
                    try await sql.raw("SET LOCAL lock_timeout = '100ms'").run()
                    return try await NWSIngestPersistence().persistArcusEvents([b], on: database, asOf: now, logger: app.logger)
                }
                Issue.record("Snapshot advancement bypassed the target acceptance lock.")
            } catch {
                #expect(String(reflecting: error).contains("55P03"))
            }
            release.continuation.yield(())
            try await target.value
            try await accept(b, on: app)
            #expect(try await ArcusGeolocationModel.query(on: app.db).filter(\.$series.$id == id).count() == 0)
            #expect(try await ArcusSeriesModel.find(id, on: app.db)?.currentRevisionUrn == b.id)
        }
    }

    @Test("late transaction failure rolls back the complete event batch")
    func lateFailureRollsBackCompleteBatch() async throws {
        try await withIntegrationTestApplication(
            setup: .configured(mode: .api, migrate: true)
        ) { app in
            let prefix = UUID().uuidString.lowercased()
            let point = makeEvent(
                urn: "urn:oid:\(prefix)-rollback-point",
                sent: now,
                geometry: .point(lon: -104.99, lat: 39.73)
            )
            let nilGeometry = makeEvent(
                urn: "urn:oid:\(prefix)-rollback-nil",
                sent: now,
                geometry: nil
            )
            let events = [point, nilGeometry]
            let urns = events.map(\.id)
            let sourceURLs = events.map(\.sourceURL)

            do {
                try await app.db.transaction { database in
                    let result = try await NWSIngestPersistence().persistArcusEvents(
                        events,
                        on: database,
                        asOf: now,
                        logger: app.logger
                    )

                    #expect(result.newSeriesCreated == 2)
                    #expect(result.newRevisionsCreated == 2)
                    #expect(result.targetOutboxQueued == 1)
                    #expect(result.notificationOutboxQueued == 2)
                    #expect(try await ArcusSeriesModel.query(on: database)
                        .filter(\.$sourceURL ~~ sourceURLs)
                        .count() == 2)
                    #expect(try await revisions(for: urns, on: database).count == 2)
                    #expect(try await targetOutboxes(for: urns, on: database).count == 1)
                    #expect(try await notificationOutboxes(for: urns, on: database).count == 2)

                    throw Rollback.forcedLateFailure
                }
                Issue.record("Expected the forced late transaction failure.")
            } catch Rollback.forcedLateFailure {
                // Expected: assert the rolled-back state using a new database connection.
            }

            #expect(try await ArcusSeriesModel.query(on: app.db)
                .filter(\.$sourceURL ~~ sourceURLs)
                .count() == 0)
            #expect(try await revisions(for: urns, on: app.db).isEmpty)
            #expect(try await targetOutboxes(for: urns, on: app.db).isEmpty)
            #expect(try await notificationOutboxes(for: urns, on: app.db).isEmpty)
        }
    }
}

private actor CoverageRaceSender: NotificationSender {
    private(set) var count = 0
    func sendNotification(app: Application, with: AlertDetails, hotAlertPayload: HotAlertAPNsPayload,
                          to: String, environment: APNsEnvironment) async throws { count += 1 }
}
