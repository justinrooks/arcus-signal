import Fluent
import Foundation
import Queues
import Vapor

public struct IngestNWSAlertsPayload: Codable, Sendable {
    public init() {}
}

public struct IngestNWSAlertsJob: AsyncJob {
    public typealias Payload = IngestNWSAlertsPayload
    public init() {}

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info("IngestNWSAlertsJob started.")
        let runTimestamp = Date()

        do {
            let ingestEvents = try await context.application.nwsIngestService.ingestOnce(
                on: context.application,
                logger: context.logger
            )

//            let persistence = try await context.application.db.transaction { database in
//                try await persistArcusEvents(
//                    ingestEvents,
//                    on: database,
//                    asOf: runTimestamp,
//                    logger: context.logger
//                )
//            }
//
//            context.logger.info(
//                "Canonical Arcus events persisted.",
//                metadata: [
//                    "inserted": .string("\(persistence.inserted)"),
//                    "updated": .string("\(persistence.updated)"),
//                    "unchanged": .string("\(persistence.unchanged)"),
//                    "duplicatesIgnored": .string("\(persistence.duplicatesIgnored)"),
//                    "supersededCollapsed": .string("\(persistence.supersededCollapsed)"),
//                    "expiredMarked": .string("\(persistence.expiredMarked)"),
//                    "targetDispatches": .string("\(persistence.targetDispatches.count)")
//                ]
//            )
//            try await dispatchTargetJobs(for: persistence.targetDispatches, context: context)

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

//private extension IngestNWSAlertsJob {
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
//    func dispatchTargetJobs(for payloads: [TargetEventRevisionPayload], context: QueueContext) async throws {
//        guard !payloads.isEmpty else { return }
//
//        let targetQueue = context.application.queues.queue(ArcusQueueLane.target.queueName)
//        for payload in payloads {
//            try await targetQueue.dispatch(TargetEventRevisionJob.self, payload)
//        }
//
//        context.logger.info(
//            "Dispatched TargetEventRevision jobs.",
//            metadata: ["count": .stringConvertible(payloads.count)]
//        )
//    }
//
//    func isUniqueConstraintViolation(_ error: any Error) -> Bool {
//        let description = String(describing: error).lowercased()
//        return description.contains("duplicate key value")
//            || description.contains("unique constraint")
//            || description.contains("23505")
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
//    func apply(_ source: ArcusEventModel, to target: ArcusEventModel) -> Bool {
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
//        changed = assignIfChanged(source.geometryJSON, to: &target.geometryJSON) || changed
//        changed = assignIfChanged(source.ugcCodes, to: &target.ugcCodes) || changed
//        changed = assignIfChanged(source.h3Resolution, to: &target.h3Resolution) || changed
//        changed = assignIfChanged(source.h3CoverHash, to: &target.h3CoverHash) || changed
//        changed = assignIfChanged(source.title, to: &target.title) || changed
//        changed = assignIfChanged(source.areaDesc, to: &target.areaDesc) || changed
//        changed = assignIfChanged(source.rawRef, to: &target.rawRef) || changed
//        changed = assignIfChanged(source.isExpired, to: &target.isExpired) || changed
//
//        return changed
//    }
//
//    func assignIfChanged<Value: Equatable>(_ newValue: Value, to target: inout Value) -> Bool {
//        guard target != newValue else { return false }
//        target = newValue
//        return true
//    }
//}
