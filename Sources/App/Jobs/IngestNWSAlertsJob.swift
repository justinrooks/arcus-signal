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

//            #if DEBUG
//            let testSeriesId = "26f46a65-847c-4e32-a881-346abe9b1551"
//            let testGeo: GeoShape
//            
//            
//            
//            #endif
            
            let drainResult = try await dispatchPendingTargetJobs(context: context)
            context.logger.info(
                "Target dispatch outbox drain finished.",
                metadata: [
                    "dispatched": .stringConvertible(drainResult.dispatched),
                    "failed": .stringConvertible(drainResult.failed)
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
            throw Abort(
                .notImplemented,
                reason: "Fixture replay source is not wired yet. Step 3 will add fixture loader support."
            )
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
        var outboxQueued = 0
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

                if try await enqueueTargetDispatchOutboxIfNeeded(
                    event: event,
                    seriesId: seriesId,
                    on: database,
                    logger: logger
                ) {
                    outboxQueued += 1
                }
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
                }
            }

            logger.info("Arcus event processed", metadata: ["revisionUrn": .string(event.id)])
        }

        return .init(
            newRevisionsCreated: insertedRevs,
            newSeriesCreated: insertedSeries,
            targetOutboxQueued: outboxQueued
        )
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
    
    
//    func persistArcusEvents(
//        _ events: [ArcusIngestEvent],
//        on database: any Database,
//        asOf: Date,
//        logger: Logger
//    ) async throws -> ArcusEventPersistenceSummary {
//        let deduplication = ArcusIngestMessageDeduplicator.deduplicate(events)
//        var summary = ArcusEventPersistenceSummary(duplicatesIgnored: deduplication.duplicatesIgnored)
//
//        guard !deduplication.events.isEmpty else {
//            summary.expiredMarked = try await markExpiredEvents(asOf: asOf, on: database, logger: logger)
//            return summary
//        }
//
//        let existingByEventKey = try await fetchExistingByEventKey(for: deduplication.events, on: database)
//        let resolvedLineages = ArcusIngestLineageResolver.resolve(
//            events: deduplication.events,
//            existingByEventKey: existingByEventKey
//        )
//        summary.supersededCollapsed = resolvedLineages.reduce(0) { $0 + $1.supersededInRun }
//
//        for lineage in resolvedLineages {
//            let winner = lineage.winner
//            let incoming = try ArcusEventModel(from: winner.event, asOf: asOf)
//
//            if let existing = lineage.existing {
//                let contentChanged = existing.contentHash != incoming.contentHash
//                let oldRevision = existing.revision
//                let oldIsExpired = existing.isExpired
//
//                if apply(incoming, to: existing) {
//                    if contentChanged {
//                        existing.revision += 1
//                    }
//                    try await existing.update(on: database)
//                    summary.updated += 1
//
//                    if TargetEventRevisionDispatchPolicy.shouldDispatchOnUpdate(
//                        contentChanged: contentChanged,
//                        isExpired: existing.isExpired
//                    ) {
//                        summary.targetDispatches.append(
//                            .init(eventKey: existing.eventKey, revision: existing.revision)
//                        )
//                    }
//
//                    emitHookEventUpdated(
//                        logger: logger,
//                        eventKey: existing.eventKey,
//                        previousRevision: oldRevision,
//                        newRevision: existing.revision,
//                        contentChanged: contentChanged
//                    )
//
//                    if oldIsExpired == false, existing.isExpired == true {
//                        emitHookEventEnded(
//                            logger: logger,
//                            eventKey: existing.eventKey,
//                            revision: existing.revision,
//                            endedAt: asOf,
//                            reason: "incoming-update"
//                        )
//                    }
//                } else {
//                    summary.unchanged += 1
//                }
//                continue
//            }
//
//            do {
//                try await incoming.create(on: database)
//                summary.inserted += 1
//
//                if TargetEventRevisionDispatchPolicy.shouldDispatchOnCreate(isExpired: incoming.isExpired) {
//                    summary.targetDispatches.append(
//                        .init(eventKey: incoming.eventKey, revision: incoming.revision)
//                    )
//                }
//
//                emitHookEventCreated(
//                    logger: logger,
//                    eventKey: incoming.eventKey,
//                    revision: incoming.revision
//                )
//            } catch {
//                guard isUniqueConstraintViolation(error) else {
//                    throw error
//                }
//
//                guard let existing = try await ArcusEventModel
//                    .query(on: database)
//                    .filter(\.$eventKey == incoming.eventKey)
//                    .sort(\.$revision, .descending)
//                    .first() else {
//                    throw error
//                }
//
//                let contentChanged = existing.contentHash != incoming.contentHash
//                let oldRevision = existing.revision
//                let oldIsExpired = existing.isExpired
//
//                if apply(incoming, to: existing) {
//                    if contentChanged {
//                        existing.revision += 1
//                    }
//                    try await existing.update(on: database)
//                    summary.updated += 1
//
//                    if TargetEventRevisionDispatchPolicy.shouldDispatchOnUpdate(
//                        contentChanged: contentChanged,
//                        isExpired: existing.isExpired
//                    ) {
//                        summary.targetDispatches.append(
//                            .init(eventKey: existing.eventKey, revision: existing.revision)
//                        )
//                    }
//
//                    emitHookEventUpdated(
//                        logger: logger,
//                        eventKey: existing.eventKey,
//                        previousRevision: oldRevision,
//                        newRevision: existing.revision,
//                        contentChanged: contentChanged
//                    )
//
//                    if oldIsExpired == false, existing.isExpired == true {
//                        emitHookEventEnded(
//                            logger: logger,
//                            eventKey: existing.eventKey,
//                            revision: existing.revision,
//                            endedAt: asOf,
//                            reason: "incoming-race-update"
//                        )
//                    }
//                } else {
//                    summary.unchanged += 1
//                }
//            }
//        }
//
//        summary.expiredMarked = try await markExpiredEvents(asOf: asOf, on: database, logger: logger)
//        return summary
//    }
//


//    func fetchExistingByEventKey(
//        for events: [ArcusIngestEvent],
//        on database: any Database
//    ) async throws -> [String: ArcusEventModel] {
//        let messageKeys = events.map(\.event.eventKey)
//        let referencedKeys = events.flatMap(\.supersededEventKeys)
//        let lookupKeys = Array(Set(messageKeys + referencedKeys))
//
//        guard !lookupKeys.isEmpty else { return [:] }
//
//        let existing = try await ArcusEventModel
//            .query(on: database)
//            .filter(\.$eventKey ~~ lookupKeys)
//            .all()
//
//        var index: [String: ArcusEventModel] = [:]
//        index.reserveCapacity(existing.count)
//
//        for model in existing {
//            if let current = index[model.eventKey], current.revision >= model.revision {
//                continue
//            }
//            index[model.eventKey] = model
//        }
//
//        return index
//    }
//
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
//
//    func apply(_ source: ArcusSeriesModel, to target: ArcusSeriesModel) -> Bool {
//        var changed = false
//
//        changed = assignIfChanged(source.eventKey, to: &target.eventKey) || changed
//        changed = assignIfChanged(source.source, to: &target.source) || changed
//        changed = assignIfChanged(source.kind, to: &target.kind) || changed
//        changed = assignIfChanged(source.sourceURL, to: &target.sourceURL) || changed
//        changed = assignIfChanged(source.status, to: &target.status) || changed
//        changed = assignIfChanged(source.contentHash, to: &target.contentHash) || changed
//        changed = assignIfChanged(source.issuedAt, to: &target.issuedAt) || changed
//        changed = assignIfChanged(source.effectiveAt, to: &target.effectiveAt) || changed
//        changed = assignIfChanged(source.expiresAt, to: &target.expiresAt) || changed
//        changed = assignIfChanged(source.severity, to: &target.severity) || changed
//        changed = assignIfChanged(source.urgency, to: &target.urgency) || changed
//        changed = assignIfChanged(source.certainty, to: &target.certainty) || changed
//        changed = assignIfChanged(source.geometry, to: &target.geometry) || changed
//        changed = assignIfChanged(source.ugcCodes, to: &target.ugcCodes) || changed
////        changed = assignIfChanged(source.h3Resolution, to: &target.h3Resolution) || changed
////        changed = assignIfChanged(source.h3CoverHash, to: &target.h3CoverHash) || changed
//        changed = assignIfChanged(source.title, to: &target.title) || changed
//        changed = assignIfChanged(source.areaDesc, to: &target.areaDesc) || changed
////        changed = assignIfChanged(source.rawRef, to: &target.rawRef) || changed
////        changed = assignIfChanged(source.isExpired, to: &target.isExpired) || changed
//
//        return changed
//    }
//
//    func assignIfChanged<Value: Equatable>(_ newValue: Value, to target: inout Value) -> Bool {
//        guard target != newValue else { return false }
//        target = newValue
//        return true
//    }
}
