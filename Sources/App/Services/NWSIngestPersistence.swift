import Fluent
import Foundation
import Vapor

struct PersistResult {
    let newRevisionsCreated: Int
    let newSeriesCreated: Int
    let targetOutboxQueued: Int
    let notificationOutboxQueued: Int
}

private struct SeriesMergeResult {
    let winnerSeriesId: UUID
    let loserSeriesIds: [UUID]
    let revisionsMoved: Int
    let pendingOutboxMoved: Int
    let geolocationsDeleted: Int
    let geolocationMovedToWinner: Bool
}

struct NWSIngestPersistence {
    func persistArcusEvents(
        _ events: [ArcusEvent],
        on database: any Database,
        asOf: Date,
        logger: Logger
    ) async throws -> PersistResult {
        var outboxQueued: Int = 0
        var notificationOutboxQueued: Int = 0
        var insertedSeries: Int = 0
        var insertedRevs: Int = 0
        for event in events {
            // Phase 1: revision-level idempotency gate (avoid duplicate work).
            if let _ = try await ArcusEventRevisionModel
                .query(on: database)
                .filter(\.$revisionUrn == event.id)
                .first() {
                logger.debug("Duplicate revision skipped", metadata: ["revisionUrn": .string(event.id)])
                continue
            }

            let seriesIds = try await ArcusEventRevisionModel.resolveSeriesIDs(
                referencedURNs: event.references,
                on: database
            )

            switch seriesIds.count {
            case 0:
                logger.info("New series detected")
                let incoming = try ArcusSeriesModel(from: event, asOf: asOf)
                try await incoming.create(on: database)
                insertedSeries += 1

                guard let seriesId = incoming.id else {
                    throw Abort(.internalServerError, reason: "Created series did not return an id.")
                }

                let revision = try ArcusEventRevisionModel(from: event, seriesId: seriesId, asOf: asOf)
                try await revision.create(on: database)
                insertedRevs += 1

                let (geoOutbox, notificationOutbox) = try await queueDispatchMessages(
                    event: event,
                    seriesId: seriesId,
                    reason: .new,
                    on: database,
                    logger: logger
                )
                outboxQueued += geoOutbox
                notificationOutboxQueued += notificationOutbox
            case 1:
                guard let seriesId = seriesIds.first else {
                    throw Abort(.internalServerError, reason: "Expected 1 seriesId but found none.")
                }

                let revision = try ArcusEventRevisionModel(from: event, seriesId: seriesId, asOf: asOf)
                try await revision.create(on: database)
                insertedRevs += 1

                guard let series = try await ArcusSeriesModel.find(seriesId, on: database) else {
                    throw Abort(.notFound, reason: "Referenced series not found: \(seriesId)")
                }

                if shouldAdvanceSeriesSnapshot(currentSent: series.currentRevisionSent, incomingSent: event.sent, logger: logger) {
                    try applySnapshot(from: event, to: series, asOf: asOf)
                    try await series.update(on: database)
                    logger.info("Series snapshot updated.", metadata: ["seriesId": .stringConvertible(seriesId)])

                    let (geoOutbox, notificationOutbox) = try await queueDispatchMessages(
                        event: event,
                        seriesId: seriesId,
                        reason: .update,
                        on: database,
                        logger: logger
                    )
                    outboxQueued += geoOutbox
                    notificationOutboxQueued += notificationOutbox
                }
            default:
                // Deterministic merge policy: winner is the series with the most recent sent timestamp.
                let mergeResult = try await mergeReferencedSeries(
                    candidateSeriesIDs: seriesIds,
                    asOf: asOf,
                    on: database
                )
                let winnerSeriesId = mergeResult.winnerSeriesId

                logger.warning(
                    "Merged referenced series to winner selected by most recent sent timestamp.",
                    metadata: [
                        "winnerSeriesId": .stringConvertible(winnerSeriesId),
                        "loserSeriesCount": .stringConvertible(mergeResult.loserSeriesIds.count),
                        "revisionsMoved": .stringConvertible(mergeResult.revisionsMoved),
                        "pendingOutboxMoved": .stringConvertible(mergeResult.pendingOutboxMoved),
                        "geolocationsDeleted": .stringConvertible(mergeResult.geolocationsDeleted),
                        "geolocationMovedToWinner": .stringConvertible(mergeResult.geolocationMovedToWinner),
                        "revisionUrn": .string(event.id)
                    ]
                )

                let revision = try ArcusEventRevisionModel(from: event, seriesId: winnerSeriesId, asOf: asOf)
                try await revision.create(on: database)
                insertedRevs += 1

                guard let series = try await ArcusSeriesModel.find(winnerSeriesId, on: database) else {
                    throw Abort(.notFound, reason: "Winner series not found: \(winnerSeriesId)")
                }

                if shouldAdvanceSeriesSnapshot(currentSent: series.currentRevisionSent, incomingSent: event.sent, logger: logger) {
                    try applySnapshot(from: event, to: series, asOf: asOf)
                    try await series.update(on: database)
                    logger.info("Winner series snapshot updated.", metadata: ["seriesId": .stringConvertible(winnerSeriesId)])

                    guard let seriesId = series.id else { throw Abort(.notFound, reason: "Series Id missing on winning series") }

                    let (geoOutbox, notificationOutbox) = try await queueDispatchMessages(
                        event: event,
                        seriesId: seriesId,
                        reason: .update,
                        on: database,
                        logger: logger
                    )
                    outboxQueued += geoOutbox
                    notificationOutboxQueued += notificationOutbox
                }
            }

            logger.info("Arcus event processed", metadata: ["revisionUrn": .string(event.id)])
        }

        return .init(
            newRevisionsCreated: insertedRevs,
            newSeriesCreated: insertedSeries,
            targetOutboxQueued: outboxQueued,
            notificationOutboxQueued: notificationOutboxQueued
        )
    }

    func shouldQueueUGCNotificationDispatch(for event: ArcusEvent) -> Bool {
        guard let geometry = event.geometry else {
            return true
        }

        switch geometry {
        case .polygon, .multiPolygon:
            return false
        case .point:
            return true
        }
    }
}

private extension NWSIngestPersistence {
    func queueDispatchMessages(
        event: ArcusEvent,
        seriesId: UUID,
        reason: NotificationReason,
        on database: any Database,
        logger: Logger
    ) async throws -> (Int, Int) {
        var outboxQueued: Int = 0
        var notificationOutboxQueued: Int = 0

        if try await enqueueTargetDispatchOutboxIfNeeded(
            event: event,
            seriesId: seriesId,
            reason: reason,
            on: database,
            logger: logger
        ) {
            outboxQueued += 1
            logger.info("Geometry job queued.", metadata: ["seriesId": .stringConvertible(seriesId)])
        }

        if shouldQueueUGCNotificationDispatch(for: event) {
            if try await DispatchAgent.enqueueNotificationDispatchOutbox(
                revisionUrn: event.id,
                seriesId: seriesId,
                reason: reason,
                mode: .ugc,
                on: database,
                logger: logger
            ) {
                notificationOutboxQueued += 1
                logger.info("Notification job queued.", metadata: ["seriesId": .stringConvertible(seriesId)])
            }
        }

        return (outboxQueued, notificationOutboxQueued)
    }

    func shouldAdvanceSeriesSnapshot(
        currentSent: Date?,
        incomingSent: Date?,
        logger: Logger
    ) -> Bool {
        guard let incomingSent else {
            logger.info("Skipping snapshot update due to missing incoming sent timestamp.")
            return false
        }

        guard let currentSent else {
            return true
        }

        guard incomingSent >= currentSent else {
            logger.info("Skipping snapshot update because incoming revision is older than current snapshot.")
            return false
        }

        return true
    }

    func applySnapshot(
        from event: ArcusEvent,
        to series: ArcusSeriesModel,
        asOf: Date
    ) throws {
        var stateHolder = event.state
        if let vtec = event.vtec {
            if vtec.status.lowercased() == "can" {
                stateHolder = EventState.cancelled
            }
//            NEW  New event
//            CON  Event continued
//            EXT  Event extended (time)
//            EXA  Event extended (area)
//            EXB  Event extended (both time and area)
//            UPG  Event upgraded
//            CAN  Event cancelled
//            EXP  Event expired
//            COR  Correction
//            ROU  Routine
        }

        series.source = event.source.rawValue
        series.event = event.kind
        series.sourceURL = event.sourceURL
        series.currentRevisionUrn = event.id
        series.currentRevisionSent = event.sent
        series.messageType = event.messageType.rawValue
        series.state = stateHolder.rawValue
        series.sent = event.sent
        series.effective = event.effective
        series.onset = event.onset
        series.expires = event.expires
        series.ends = event.ends
        series.lastSeenActive = asOf
        series.severity = event.severity.rawValue
        series.urgency = event.urgency.rawValue
        series.certainty = event.certainty.rawValue
        series.ugcCodes = event.ugcCodes
        series.title = event.title
        series.areaDesc = event.areaDesc
        series.category = event.category
        series.senderName = event.senderName
        series.headline = event.headline
        series.description = event.description
        series.instructions = event.instructions
        series.response = event.response
        series.status  = event.status
        series.tornadoDetection = event.tornadoDetection
        series.tornadoDamageThreat = event.tornadoDamageThreat
        series.maxWindGust = event.maxWindGust
        series.maxHailSize = event.maxHailSize
        series.windThreat = event.windThreat
        series.hailThreat = event.hailThreat
        series.thunderstormDamageThreat = event.thunderstormDamageThreat
        series.flashFloodDetection = event.flashFloodDetection
        series.flashFloodDamageThreat = event.flashFloodDamageThreat

        series.contentFingerprint = try event.computeContentFingerprint()
    }

    func enqueueTargetDispatchOutboxIfNeeded(
        event: ArcusEvent,
        seriesId: UUID,
        reason: NotificationReason,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        guard let geometry = event.geometry else {
            return false
        }

        let outboxRecord = ArcusTargetDispatchOutboxModel(
            revisionUrn: event.id,
            seriesId: seriesId,
            payload: .init(
                seriesId: seriesId,
                revisionUrn: event.id,
                geometry: geometry,
                reason: reason
            )
        )

        do {
            try await outboxRecord.create(on: database)
            return true
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                logger.debug(
                    "Target dispatch already queued for revision.",
                    metadata: ["revisionUrn": .string(event.id)]
                )
                return false
            }

            throw error
        }
    }

    func mergeReferencedSeries(
        candidateSeriesIDs: Set<UUID>,
        asOf: Date,
        on database: any Database
    ) async throws -> SeriesMergeResult {
        guard candidateSeriesIDs.count > 1 else {
            guard let winner = candidateSeriesIDs.first else {
                throw Abort(.internalServerError, reason: "Expected at least one candidate series id.")
            }

            return .init(
                winnerSeriesId: winner,
                loserSeriesIds: [],
                revisionsMoved: 0,
                pendingOutboxMoved: 0,
                geolocationsDeleted: 0,
                geolocationMovedToWinner: false
            )
        }

        let seriesRows = try await ArcusSeriesModel.query(on: database)
            .filter(\.$id ~~ Array(candidateSeriesIDs))
            .all()

        guard !seriesRows.isEmpty else {
            throw Abort(.internalServerError, reason: "Unable to resolve candidate series rows for merge.")
        }

        let ranked = seriesRows.sorted { lhs, rhs in
            let lhsSent = lhs.currentRevisionSent ?? .distantPast
            let rhsSent = rhs.currentRevisionSent ?? .distantPast
            if lhsSent != rhsSent {
                return lhsSent > rhsSent
            }
            let lhsID = lhs.id?.uuidString ?? ""
            let rhsID = rhs.id?.uuidString ?? ""
            return lhsID < rhsID
        }

        guard let winnerSeriesId = ranked.first?.id else {
            throw Abort(.internalServerError, reason: "Winner series row missing id.")
        }

        let loserSeriesIDs = ranked.compactMap(\.id).filter { $0 != winnerSeriesId }

        guard !loserSeriesIDs.isEmpty else {
            return .init(
                winnerSeriesId: winnerSeriesId,
                loserSeriesIds: [],
                revisionsMoved: 0,
                pendingOutboxMoved: 0,
                geolocationsDeleted: 0,
                geolocationMovedToWinner: false
            )
        }

        // Repoint all revisions from loser series to winner series.
        let revisionsToMove = try await ArcusEventRevisionModel.query(on: database)
            .filter(\.$series.$id ~~ loserSeriesIDs)
            .all()
        for revision in revisionsToMove {
            revision.$series.id = winnerSeriesId
            try await revision.update(on: database)
        }

        // Repoint any pending outbox records and rewrite payload series id.
        let pendingOutbox = try await ArcusTargetDispatchOutboxModel.query(on: database)
            .filter(\.$series.$id ~~ loserSeriesIDs)
            .filter(\.$dispatched == nil)
            .all()
        for row in pendingOutbox {
            row.$series.id = winnerSeriesId
            row.payload = .init(
                seriesId: winnerSeriesId,
                revisionUrn: row.payload.revisionUrn,
                geometry: row.payload.geometry,
                reason: row.payload.reason
            )
            try await row.update(on: database)
        }

        let geolocations = try await ArcusGeolocationModel.query(on: database)
            .filter(\.$series.$id ~~ (loserSeriesIDs + [winnerSeriesId]))
            .all()
        let winnerGeolocation = geolocations.first { $0.$series.id == winnerSeriesId }
        let loserGeolocations = geolocations.filter { $0.$series.id != winnerSeriesId }

        var movedGeolocationID: UUID?
        var geolocationMovedToWinner = false
        if winnerGeolocation == nil, let newestLoserGeo = newestGeolocation(from: loserGeolocations) {
            newestLoserGeo.$series.id = winnerSeriesId
            try await newestLoserGeo.update(on: database)
            movedGeolocationID = newestLoserGeo.id
            geolocationMovedToWinner = true
        }

        var geolocationsDeleted = 0
        for geo in loserGeolocations {
            if let movedGeolocationID, geo.id == movedGeolocationID {
                continue
            }
            try await geo.delete(on: database)
            geolocationsDeleted += 1
        }

        // Tombstone loser series rows instead of deleting to avoid breaking in-flight references.
        let loserSeries = try await ArcusSeriesModel.query(on: database)
            .filter(\.$id ~~ loserSeriesIDs)
            .all()
        for loser in loserSeries {
            loser.state = "expired"
            loser.lastSeenActive = asOf
            try await loser.update(on: database)
        }

        return .init(
            winnerSeriesId: winnerSeriesId,
            loserSeriesIds: loserSeriesIDs,
            revisionsMoved: revisionsToMove.count,
            pendingOutboxMoved: pendingOutbox.count,
            geolocationsDeleted: geolocationsDeleted,
            geolocationMovedToWinner: geolocationMovedToWinner
        )
    }

    func newestGeolocation(from rows: [ArcusGeolocationModel]) -> ArcusGeolocationModel? {
        rows.max { lhs, rhs in
            geolocationSortDate(lhs) < geolocationSortDate(rhs)
        }
    }

    func geolocationSortDate(_ row: ArcusGeolocationModel) -> Date {
        row.updated ?? row.created ?? .distantPast
    }
}
