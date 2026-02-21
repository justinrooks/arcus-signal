import Fluent
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

        do {
            let arcusEvents = try await context.application.nwsIngestService.ingestOnce(
                on: context.application,
                logger: context.logger
            )

            let persistence = try await upsertArcusEvents(
                arcusEvents,
                on: context.application.db
            )
            context.logger.info(
                "Canonical Arcus events persisted.",
                metadata: [
                    "inserted": .string("\(persistence.inserted)"),
                    "updated": .string("\(persistence.updated)")
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
    typealias ArcusEventPersistenceCounts = (inserted: Int, updated: Int)

    func upsertArcusEvents(
        _ events: [ArcusEvent],
        on database: any Database
    ) async throws -> ArcusEventPersistenceCounts {
        guard !events.isEmpty else {
            return (inserted: 0, updated: 0)
        }

        var inserted = 0
        var updated = 0

        for event in events {
            if let existing = try await ArcusEventModel
                .query(on: database)
                .filter(\.$eventKey == event.eventKey)
                .filter(\.$revision == event.revision)
                .first() {
                try apply(event, to: existing)
                try await existing.update(on: database)
                updated += 1
                continue
            }

            let model = try ArcusEventModel(from: event)
            do {
                try await model.create(on: database)
                inserted += 1
            } catch {
                guard isUniqueConstraintViolation(error) else {
                    throw error
                }

                // Rare race: another worker inserted this row after our existence check.
                guard let existing = try await ArcusEventModel
                    .query(on: database)
                    .filter(\.$eventKey == event.eventKey)
                    .filter(\.$revision == event.revision)
                    .first() else {
                    throw error
                }

                try apply(event, to: existing)
                try await existing.update(on: database)
                updated += 1
            }
        }

        return (inserted: inserted, updated: updated)
    }

    func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("duplicate key value")
            || description.contains("unique constraint")
            || description.contains("23505")
    }

    func apply(_ event: ArcusEvent, to model: ArcusEventModel) throws {
        let updated = try ArcusEventModel(from: event)

        model.eventKey = updated.eventKey
        model.source = updated.source
        model.kind = updated.kind
        model.sourceURL = updated.sourceURL
        model.status = updated.status
        model.revision = updated.revision
        model.issuedAt = updated.issuedAt
        model.effectiveAt = updated.effectiveAt
        model.expiresAt = updated.expiresAt
        model.severity = updated.severity
        model.urgency = updated.urgency
        model.certainty = updated.certainty
        model.geometryJSON = updated.geometryJSON
        model.ugcCodes = updated.ugcCodes
        model.h3Resolution = updated.h3Resolution
        model.h3CoverHash = updated.h3CoverHash
        model.title = updated.title
        model.areaDesc = updated.areaDesc
        model.rawRef = updated.rawRef
    }
}
