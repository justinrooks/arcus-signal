@testable import App
import Fluent
import Foundation
import Testing
import Vapor

@Suite("NWS ingest persistence flow", .serialized)
struct NWSIngestPersistenceFlowTests {
    private enum Rollback: Error {
        case afterAssertions
        case forcedLateFailure
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func withRollbackTransaction(
        on app: Application,
        test: @escaping @Sendable (any Database) async throws -> Void
    ) async throws {
        do {
            try await app.db.transaction { database in
                try await test(database)
                throw Rollback.afterAssertions
            }
        } catch Rollback.afterAssertions {
            // Expected: keep the shared integration database unchanged.
        }
    }

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
        try await withApp { app in
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

                let result = try await IngestNWSAlertsJob().persistArcusEvents(
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
        try await withApp { app in
            try await withRollbackTransaction(on: app) { database in
                let prefix = UUID().uuidString.lowercased()
                let event = makeEvent(
                    urn: "urn:oid:\(prefix)-duplicate",
                    sent: now,
                    geometry: .point(lon: -104.99, lat: 39.73)
                )

                let first = try await IngestNWSAlertsJob().persistArcusEvents(
                    [event],
                    on: database,
                    asOf: now,
                    logger: app.logger
                )
                let duplicate = try await IngestNWSAlertsJob().persistArcusEvents(
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
        try await withApp { app in
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

                let result = try await IngestNWSAlertsJob().persistArcusEvents(
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
        try await withApp { app in
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
                _ = try await IngestNWSAlertsJob().persistArcusEvents(
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

                var geolocationIDsBySeries: [UUID: UUID] = [:]
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
                    geolocationIDsBySeries[seriesID] = try geolocation.requireID()
                }

                let merge = makeEvent(
                    urn: "urn:oid:\(prefix)-merge",
                    references: bases.map(\.id),
                    sent: now.addingTimeInterval(240),
                    geometry: polygon(offset: 0.3)
                )
                let mergeResult = try await IngestNWSAlertsJob().persistArcusEvents(
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
                let winnerGeolocationID = try #require(geolocationIDsBySeries[winnerSeriesID])
                #expect(geolocations.count == 1)
                #expect(geolocations.first?.id == winnerGeolocationID)
                #expect(geolocations.first?.$series.id == winnerSeriesID)
                #expect(geolocations.first?.geometryHash == "geometry-0")
                #expect(try await notificationOutboxes(for: allUrns, on: database).isEmpty)
            }
        }
    }

    @Test("late transaction failure rolls back the complete event batch")
    func lateFailureRollsBackCompleteBatch() async throws {
        try await withApp { app in
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
                    let result = try await IngestNWSAlertsJob().persistArcusEvents(
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
