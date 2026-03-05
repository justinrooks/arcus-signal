import Fluent
import Foundation
import Queues
import Vapor

public enum IngestNWSAlertsSource: String, Codable, Sendable {
    case live
    case fixture
}

public struct IngestNWSAlertsPayload: Codable, Sendable {
    public let source: IngestNWSAlertsSource
    public let fixtureName: String?
    public let runLabel: String?

    public init(
        source: IngestNWSAlertsSource = .live,
        fixtureName: String? = nil,
        runLabel: String? = nil
    ) {
        self.source = source
        self.fixtureName = fixtureName
        self.runLabel = runLabel
    }
}

private struct PersistResult {
    let newRevisionsCreated: Int
    let newSeriesCreated: Int
    let targetOutboxQueued: Int
    let notificationOutboxQueued: Int
}

private struct DispatchDrainResult {
    let dispatched: Int
    let failed: Int
}

private struct SeriesMergeResult {
    let winnerSeriesId: UUID
    let loserSeriesIds: [UUID]
    let revisionsMoved: Int
    let pendingOutboxMoved: Int
    let geolocationsDeleted: Int
    let geolocationMovedToWinner: Bool
}

public struct IngestNWSAlertsJob: AsyncJob {
    public typealias Payload = IngestNWSAlertsPayload
    public init() {}

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info(
            "IngestNWSAlertsJob started.",
            metadata: [
                "source": .string(payload.source.rawValue),
                "fixtureName": .string(payload.fixtureName ?? "none"),
                "runLabel": .string(payload.runLabel ?? "none")
            ]
        )
        let runTimestamp = Date()

        do {
            let ingestEvents = try await resolveIngestEvents(
                for: payload,
                context: context
            )

            let result = try await context.application.db.transaction{ database in
                try await persistArcusEvents(ingestEvents, on: database, asOf: runTimestamp, logger: context.logger)
            }
            context.logger.info(
                "Arcus events persisted.",
                metadata: [
                    "newSeries": .string("\(result.newSeriesCreated)"),
                    "newRevs": .string("\(result.newRevisionsCreated)"),
                    "targetOutboxQueued": .string("\(result.targetOutboxQueued)")
                ])

            let drainResult = try await dispatchPendingTargetJobs(context: context)
            context.logger.info(
                "Target dispatch outbox drain finished.",
                metadata: [
                    "dispatched": .stringConvertible(drainResult.dispatched),
                    "failed": .stringConvertible(drainResult.failed)
                ]
            )
            let drainNotificationsResult = try await dispatchPendingNotificationJobs(context: context)
            context.logger.info(
                "Notification dispatch outbox drain finished.",
                metadata: [
                    "dispatched": .stringConvertible(drainNotificationsResult.dispatched),
                    "failed": .stringConvertible(drainNotificationsResult.failed)
                ]
            )
            
            context.logger.info("IngestNWSAlertsJob finished.")
        } catch {
            context.logger.report(error: error)
            throw error
        }
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "IngestNWSAlertsJob failed.",
            metadata: ["error": .string(String(describing: error))]
        )
    }
}

private extension IngestNWSAlertsJob {
    func resolveIngestEvents(
        for payload: IngestNWSAlertsPayload,
        context: QueueContext
    ) async throws -> [ArcusEvent] {
        switch payload.source {
        case .live:
            return try await context.application.nwsIngestService.ingestOnce(
                on: context.application,
                logger: context.logger
            )
        case .fixture:
            guard let fixtureName = payload.fixtureName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  fixtureName.isEmpty == false else {
                throw Abort(.badRequest, reason: "Fixture source requires fixtureName.")
            }

            do {
                return try context.application.nwsReplayFixtureLoader.loadEvents(
                    fixtureName: fixtureName,
                    on: context.application,
                    logger: context.logger
                )
            } catch NWSReplayFixtureLoaderError.invalidFixtureName {
                throw Abort(.badRequest, reason: "Invalid fixtureName.")
            } catch let NWSReplayFixtureLoaderError.fixtureNotFound(path) {
                throw Abort(.notFound, reason: "Fixture file not found at path: \(path)")
            }
        }
    }

    func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("duplicate key value")
        || description.contains("unique constraint")
        || description.contains("23505")
    }
    
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
    
    private func queueDispatchMessages(
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
            on: database,
            logger: logger
        ) {
            outboxQueued += 1
            logger.info("Geometry job queued.", metadata: ["seriesId": .stringConvertible(seriesId)])
        }
        
        if try await enqueueNotificationDispatchOutbox(
            event: event,
            seriesId: seriesId,
            reason: reason,
            on: database,
            logger: logger
        ) {
            notificationOutboxQueued += 1
            logger.info("Notification job queued.", metadata: ["seriesId": .stringConvertible(seriesId)])
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
        series.source = event.source.rawValue
        series.event = event.kind.rawValue
        series.sourceURL = event.sourceURL
        series.currentRevisionUrn = event.id
        series.currentRevisionSent = event.sent
        series.messageType = event.messageType.rawValue
        series.state = event.state.rawValue
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
        series.contentFingerprint = try event.computeContentFingerprint()
    }
    
    func enqueueTargetDispatchOutboxIfNeeded(
        event: ArcusEvent,
        seriesId: UUID,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        guard let geometry = event.geometry else {
            return false
        }

        let outboxRecord = ArcusTargetDispatchOutboxModel(
            revisionUrn: event.id,
            seriesId: seriesId,
            payload: .init(seriesId: seriesId, geometry: geometry)
        )

        do {
            try await outboxRecord.create(on: database)
            return true
        } catch {
            if isUniqueConstraintViolation(error) {
                logger.debug(
                    "Target dispatch already queued for revision.",
                    metadata: ["revisionUrn": .string(event.id)]
                )
                return false
            }

            throw error
        }
    }
    
    func enqueueNotificationDispatchOutbox(
        event: ArcusEvent,
        seriesId: UUID,
        reason: NotificationReason,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        // TODO: reason will be implemented later
        
        // ensure that we have no geometry so we fall back
        // to ugc codes
        guard event.geometry == nil else {
            return false
        }
        
        let outboxRecord = ArcusNotificationOutboxModel(
            series: seriesId,
            revisionUrn: event.id,
            mode: NotificationTargetMode.ugc.rawValue,
            state: "ready",
            attempts: 0,
            availableAt: .now
        )
        
        do {
            try await outboxRecord.create(on: database)
            return true
        } catch {
            if isUniqueConstraintViolation(error) {
                logger.debug(
                    "Notification dispatch already queued for revision.",
                    metadata: ["revisionUrn": .string(event.id)]
                )
                return false
            }

            throw error
        }
    }

    func dispatchPendingNotificationJobs(
        context: QueueContext,
        limit: Int = 250
    ) async throws -> DispatchDrainResult {
        let pendingRows = try await ArcusNotificationOutboxModel.query(on: context.application.db)
            .filter(\.$state == "ready")
            .sort(\.$created, .ascending)
            .limit(limit)
            .all()

        guard !pendingRows.isEmpty else {
            return .init(dispatched: 0, failed: 0)
        }

        let sendQueue = context.application.queues.queue(ArcusQueueLane.send.queueName)
        var dispatched = 0
        var failed = 0

        for row in pendingRows {
            do {
                guard let mode = NotificationTargetMode(rawValue: row.mode) else {
                    throw ArcusEventModelError.invalidEnum(field: "mode", value: row.mode)
                }
                
                let pl: NotificationSendJobPayload = .init(
                    seriesId: row.$series.id,
                    revisionUrn: row.revisionUrn,
                    mode: mode,
                    reason: .new
                )
                
                try await sendQueue.dispatch(NotificationSendJob.self, pl)
                row.availableAt = Date()
                row.lastError = nil
                row.attempts += 1
                row.state = "processing"
                
                try await row.update(on: context.application.db)
                dispatched += 1
            } catch {
                failed += 1
                row.attempts += 1
                row.lastError = String(reflecting: error)
                try? await row.update(on: context.application.db)

                context.logger.error(
                    "Failed to dispatch notifcation job from outbox.",
                    metadata: [
                        "outboxId": .string(row.id?.uuidString ?? "unknown"),
                        "revisionUrn": .string(row.revisionUrn),
                        "error": .string(String(reflecting: error))
                    ]
                )
            }
        }

        return .init(dispatched: dispatched, failed: failed)
    }
    
    func dispatchPendingTargetJobs(
        context: QueueContext,
        limit: Int = 250
    ) async throws -> DispatchDrainResult {
        let pendingRows = try await ArcusTargetDispatchOutboxModel.query(on: context.application.db)
            .filter(\.$dispatched == nil)
            .sort(\.$created, .ascending)
            .limit(limit)
            .all()

        guard !pendingRows.isEmpty else {
            return .init(dispatched: 0, failed: 0)
        }

        let targetQueue = context.application.queues.queue(ArcusQueueLane.target.queueName)
        var dispatched = 0
        var failed = 0

        for row in pendingRows {
            do {
                try await targetQueue.dispatch(TargetEventRevisionJob.self, row.payload)
                row.dispatched = Date()
                row.lastError = nil
                row.attemptCount += 1
                try await row.update(on: context.application.db)
                dispatched += 1
            } catch {
                failed += 1
                row.attemptCount += 1
                row.lastError = String(reflecting: error)
                try? await row.update(on: context.application.db)

                context.logger.error(
                    "Failed to dispatch target job from outbox.",
                    metadata: [
                        "outboxId": .string(row.id?.uuidString ?? "unknown"),
                        "revisionUrn": .string(row.revisionUrn),
                        "error": .string(String(reflecting: error))
                    ]
                )
            }
        }

        return .init(dispatched: dispatched, failed: failed)
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
            row.payload = .init(seriesId: winnerSeriesId, geometry: row.payload.geometry)
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
    
//
//                    emitHookEventUpdated(
//                        logger: logger,
//                        eventKey: existing.eventKey,
//                        previousRevision: oldRevision,
//                        newRevision: existing.revision,
//                        contentChanged: contentChanged
//                    )

//                emitHookEventCreated(
//                    logger: logger,
//                    eventKey: incoming.eventKey,
//                    revision: incoming.revision
//                )

//    func markExpiredEvents(
//        asOf: Date,
//        on database: any Database,
//        logger: Logger
//    ) async throws -> Int {
//        let toExpire = try await ArcusEventModel
//            .query(on: database)
//            .filter(\.$isExpired == false)
//            .filter(\.$expiresAt <= asOf)
//            .all()
//
//        guard !toExpire.isEmpty else { return 0 }
//
//        try await ArcusEventModel
//            .query(on: database)
//            .filter(\.$isExpired == false)
//            .filter(\.$expiresAt <= asOf)
//            .set(\.$isExpired, to: true)
//            .set(\.$status, to: EventStatus.ended.rawValue)
//            .update()
//
//        for model in toExpire {
//            emitHookEventEnded(
//                logger: logger,
//                eventKey: model.eventKey,
//                revision: model.revision,
//                endedAt: asOf,
//                reason: "ends-backfill"
//            )
//        }
//
//        return toExpire.count
//    }
//
//    func emitHookEventCreated(
//        logger: Logger,
//        eventKey: String,
//        revision: Int
//    ) {
//        logger.info(
//            "HOOK event-created",
//            metadata: [
//                "eventKey": .string(eventKey),
//                "revision": .stringConvertible(revision)
//            ]
//        )
//    }
//
//    func emitHookEventUpdated(
//        logger: Logger,
//        eventKey: String,
//        previousRevision: Int,
//        newRevision: Int,
//        contentChanged: Bool
//    ) {
//        logger.info(
//            "HOOK event-updated",
//            metadata: [
//                "eventKey": .string(eventKey),
//                "previousRevision": .stringConvertible(previousRevision),
//                "newRevision": .stringConvertible(newRevision),
//                "contentChanged": .stringConvertible(contentChanged)
//            ]
//        )
//    }
//
//    func emitHookEventEnded(
//        logger: Logger,
//        eventKey: String,
//        revision: Int,
//        endedAt: Date,
//        reason: String
//    ) {
//        logger.info(
//            "HOOK event-ended",
//            metadata: [
//                "eventKey": .string(eventKey),
//                "revision": .stringConvertible(revision),
//                "endedAt": .string(ISO8601DateFormatter().string(from: endedAt)),
//                "reason": .string(reason)
//            ]
//        )
//    }
}
