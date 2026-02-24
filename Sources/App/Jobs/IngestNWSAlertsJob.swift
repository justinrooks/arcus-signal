import Fluent
import Foundation
import Queues
import Vapor

public struct IngestNWSAlertsPayload: Codable, Sendable {
    public init() {}
}

struct ArcusEventLookupKey: Hashable, Sendable {
    let eventKey: String
}

struct ArcusEventDeduplicationResult: Sendable {
    let events: [ArcusEvent]
    let duplicatesIgnored: Int
}

enum ArcusEventDeduplicator {
    static func deduplicate(_ events: [ArcusEvent]) -> ArcusEventDeduplicationResult {
        guard !events.isEmpty else {
            return .init(events: [], duplicatesIgnored: 0)
        }

        var indexByKey: [ArcusEventLookupKey: Int] = [:]
        var deduped: [ArcusEvent] = []
        var duplicatesIgnored = 0
        deduped.reserveCapacity(events.count)

        for event in events {
            let key = ArcusEventLookupKey(eventKey: event.eventKey)
            if let existingIndex = indexByKey[key] {
                deduped[existingIndex] = event
                duplicatesIgnored += 1
            } else {
                indexByKey[key] = deduped.count
                deduped.append(event)
            }
        }

        return .init(events: deduped, duplicatesIgnored: duplicatesIgnored)
    }
}

struct ArcusEventPersistenceSummary: Sendable {
    var inserted: Int
    var updated: Int
    var unchanged: Int
    var duplicatesIgnored: Int
    var expiredMarked: Int

    init(
        inserted: Int = 0,
        updated: Int = 0,
        unchanged: Int = 0,
        duplicatesIgnored: Int = 0,
        expiredMarked: Int = 0
    ) {
        self.inserted = inserted
        self.updated = updated
        self.unchanged = unchanged
        self.duplicatesIgnored = duplicatesIgnored
        self.expiredMarked = expiredMarked
    }
}

public struct IngestNWSAlertsJob: AsyncJob {
    public typealias Payload = IngestNWSAlertsPayload
    public init() {}

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info("IngestNWSAlertsJob started.")
        let runTimestamp = Date()

        do {
            let arcusEvents = try await context.application.nwsIngestService.ingestOnce(
                on: context.application,
                logger: context.logger
            )

            let persistence = try await context.application.db.transaction { database in
                try await persistArcusEvents(
                    arcusEvents,
                    on: database,
                    asOf: runTimestamp,
                    logger: context.logger
                )
            }

            context.logger.info(
                "Canonical Arcus events persisted.",
                metadata: [
                    "inserted": .string("\(persistence.inserted)"),
                    "updated": .string("\(persistence.updated)"),
                    "unchanged": .string("\(persistence.unchanged)"),
                    "duplicatesIgnored": .string("\(persistence.duplicatesIgnored)"),
                    "expiredMarked": .string("\(persistence.expiredMarked)")
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
    typealias ArcusEventLookupIndex = [ArcusEventLookupKey: ArcusEventModel]

    func persistArcusEvents(
        _ events: [ArcusEvent],
        on database: any Database,
        asOf: Date,
        logger: Logger
    ) async throws -> ArcusEventPersistenceSummary {
        let deduplication = ArcusEventDeduplicator.deduplicate(events)
        var summary = ArcusEventPersistenceSummary(duplicatesIgnored: deduplication.duplicatesIgnored)

        guard !deduplication.events.isEmpty else {
            summary.expiredMarked = try await markExpiredEvents(asOf: asOf, on: database, logger: logger)
            return summary
        }

        var existingByKey = try await fetchExistingIndex(for: deduplication.events, on: database)
        for event in deduplication.events {
            let key = ArcusEventLookupKey(eventKey: event.eventKey)
            let incoming = try ArcusEventModel(from: event, asOf: asOf)

            if let existing = existingByKey[key] {
                let contentChanged = existing.contentHash != incoming.contentHash
                let oldRevision = existing.revision
                let oldIsExpired = existing.isExpired
                if apply(incoming, to: existing) {
                    if contentChanged {
                        existing.revision += 1
                    }
                    try await existing.update(on: database)
                    summary.updated += 1
                    emitHookEventUpdated(
                        logger: logger,
                        eventKey: existing.eventKey,
                        previousRevision: oldRevision,
                        newRevision: existing.revision,
                        contentChanged: contentChanged
                    )
                    if oldIsExpired == false, existing.isExpired == true {
                        emitHookEventEnded(
                            logger: logger,
                            eventKey: existing.eventKey,
                            revision: existing.revision,
                            endedAt: asOf,
                            reason: "incoming-update"
                        )
                    }
                } else {
                    summary.unchanged += 1
                }
                continue
            }

            do {
                try await incoming.create(on: database)
                existingByKey[key] = incoming
                summary.inserted += 1
                emitHookEventCreated(
                    logger: logger,
                    eventKey: incoming.eventKey,
                    revision: incoming.revision
                )
            } catch {
                guard isUniqueConstraintViolation(error) else {
                    throw error
                }

                // Rare race: another worker inserted this row after our existence check.
                guard let existing = try await ArcusEventModel
                    .query(on: database)
                    .filter(\.$eventKey == event.eventKey)
                    .sort(\.$revision, .descending)
                    .first() else {
                    throw error
                }

                existingByKey[key] = existing
                let contentChanged = existing.contentHash != incoming.contentHash
                let oldRevision = existing.revision
                let oldIsExpired = existing.isExpired
                if apply(incoming, to: existing) {
                    if contentChanged {
                        existing.revision += 1
                    }
                    try await existing.update(on: database)
                    summary.updated += 1
                    emitHookEventUpdated(
                        logger: logger,
                        eventKey: existing.eventKey,
                        previousRevision: oldRevision,
                        newRevision: existing.revision,
                        contentChanged: contentChanged
                    )
                    if oldIsExpired == false, existing.isExpired == true {
                        emitHookEventEnded(
                            logger: logger,
                            eventKey: existing.eventKey,
                            revision: existing.revision,
                            endedAt: asOf,
                            reason: "incoming-race-update"
                        )
                    }
                } else {
                    summary.unchanged += 1
                }
            }
        }

        summary.expiredMarked = try await markExpiredEvents(asOf: asOf, on: database, logger: logger)
        return summary
    }

    func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("duplicate key value")
            || description.contains("unique constraint")
            || description.contains("23505")
    }

    func fetchExistingIndex(
        for events: [ArcusEvent],
        on database: any Database
    ) async throws -> ArcusEventLookupIndex {
        let keys = Array(Set(events.map(\.eventKey)))
        guard !keys.isEmpty else { return [:] }

        let existing = try await ArcusEventModel
            .query(on: database)
            .filter(\.$eventKey ~~ keys)
            .all()

        var index: ArcusEventLookupIndex = [:]
        index.reserveCapacity(existing.count)
        for model in existing {
            let key = ArcusEventLookupKey(eventKey: model.eventKey)
            if let current = index[key], current.revision >= model.revision {
                continue
            }
            index[key] = model
        }
        return index
    }

    func markExpiredEvents(
        asOf: Date,
        on database: any Database,
        logger: Logger
    ) async throws -> Int {
        let toExpire = try await ArcusEventModel
            .query(on: database)
            .filter(\.$isExpired == false)
            .filter(\.$expiresAt <= asOf)
            .all()

        guard !toExpire.isEmpty else { return 0 }

        try await ArcusEventModel
            .query(on: database)
            .filter(\.$isExpired == false)
            .filter(\.$expiresAt <= asOf)
            .set(\.$isExpired, to: true)
            .set(\.$status, to: EventStatus.ended.rawValue)
            .update()

        for model in toExpire {
            emitHookEventEnded(
                logger: logger,
                eventKey: model.eventKey,
                revision: model.revision,
                endedAt: asOf,
                reason: "expiry-backfill"
            )
        }

        return toExpire.count
    }

    func emitHookEventCreated(
        logger: Logger,
        eventKey: String,
        revision: Int
    ) {
        logger.info(
            "HOOK event-created",
            metadata: [
                "eventKey": .string(eventKey),
                "revision": .stringConvertible(revision)
            ]
        )
    }

    func emitHookEventUpdated(
        logger: Logger,
        eventKey: String,
        previousRevision: Int,
        newRevision: Int,
        contentChanged: Bool
    ) {
        logger.info(
            "HOOK event-updated",
            metadata: [
                "eventKey": .string(eventKey),
                "previousRevision": .stringConvertible(previousRevision),
                "newRevision": .stringConvertible(newRevision),
                "contentChanged": .stringConvertible(contentChanged)
            ]
        )
    }

    func emitHookEventEnded(
        logger: Logger,
        eventKey: String,
        revision: Int,
        endedAt: Date,
        reason: String
    ) {
        logger.info(
            "HOOK event-ended",
            metadata: [
                "eventKey": .string(eventKey),
                "revision": .stringConvertible(revision),
                "endedAt": .string(ISO8601DateFormatter().string(from: endedAt)),
                "reason": .string(reason)
            ]
        )
    }

    func apply(_ source: ArcusEventModel, to target: ArcusEventModel) -> Bool {
        var changed = false

        changed = assignIfChanged(source.eventKey, to: &target.eventKey) || changed
        changed = assignIfChanged(source.source, to: &target.source) || changed
        changed = assignIfChanged(source.kind, to: &target.kind) || changed
        changed = assignIfChanged(source.sourceURL, to: &target.sourceURL) || changed
        changed = assignIfChanged(source.status, to: &target.status) || changed
        changed = assignIfChanged(source.contentHash, to: &target.contentHash) || changed
        changed = assignIfChanged(source.issuedAt, to: &target.issuedAt) || changed
        changed = assignIfChanged(source.effectiveAt, to: &target.effectiveAt) || changed
        changed = assignIfChanged(source.expiresAt, to: &target.expiresAt) || changed
        changed = assignIfChanged(source.severity, to: &target.severity) || changed
        changed = assignIfChanged(source.urgency, to: &target.urgency) || changed
        changed = assignIfChanged(source.certainty, to: &target.certainty) || changed
        changed = assignIfChanged(source.geometryJSON, to: &target.geometryJSON) || changed
        changed = assignIfChanged(source.ugcCodes, to: &target.ugcCodes) || changed
        changed = assignIfChanged(source.h3Resolution, to: &target.h3Resolution) || changed
        changed = assignIfChanged(source.h3CoverHash, to: &target.h3CoverHash) || changed
        changed = assignIfChanged(source.title, to: &target.title) || changed
        changed = assignIfChanged(source.areaDesc, to: &target.areaDesc) || changed
        changed = assignIfChanged(source.rawRef, to: &target.rawRef) || changed
        changed = assignIfChanged(source.isExpired, to: &target.isExpired) || changed

        return changed
    }

    func assignIfChanged<Value: Equatable>(_ newValue: Value, to target: inout Value) -> Bool {
        guard target != newValue else { return false }
        target = newValue
        return true
    }
}
