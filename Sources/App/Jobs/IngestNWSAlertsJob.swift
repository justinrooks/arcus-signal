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

struct CleanupResult {
    let expiredCount: Int
    let endedCount: Int
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
        let startedAt = Date()
        let runTimestamp = startedAt

        do {
            let ingestEvents = try await resolveIngestEvents(
                for: payload,
                context: context
            )
            
            let result = try await context.application.db.transaction { database in
                try await NWSIngestPersistence().persistArcusEvents(
                    ingestEvents,
                    on: database,
                    asOf: runTimestamp,
                    logger: context.logger
                )
            }
            context.logger.info(
                "Arcus events persisted",
                metadata: [
                    "newSeries": .string("\(result.newSeriesCreated)"),
                    "newRevs": .string("\(result.newRevisionsCreated)"),
                    "targetOutboxQueued": .string("\(result.targetOutboxQueued)"),
                    "notificationOutboxQueued": .string("\(result.notificationOutboxQueued)")
                ])

            let drainResult = try await dispatchPendingTargetJobs(context: context)
            context.logger.info(
                "Target dispatch outbox drain finished",
                metadata: [
                    "dispatched": .stringConvertible(drainResult.dispatched),
                    "failed": .stringConvertible(drainResult.failed)
                ]
            )
            
            let drainNotificationsResult = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "ugc")
            context.logger.info(
                "Notification dispatch outbox drain finished",
                metadata: [
                    "dispatched": .stringConvertible(drainNotificationsResult.dispatched),
                    "failed": .stringConvertible(drainNotificationsResult.failed)
                ]
            )
            
            // MARK: Cleanup
            let cleanResults = try await context.application.db.transaction { database in
                try await startEventCleanup(on: database, asOf: runTimestamp, logger: context.logger)
            }
            context.logger.info(
                "Arcus events cleaned up",
                metadata: [
                    "Events Ended": .string("\(cleanResults.endedCount)"),
                    "Events Expired": .string("\(cleanResults.expiredCount)")
                ])

            await recordIngestSweepRun(
                context: context,
                payload: payload,
                status: .succeeded,
                startedAt: startedAt,
                completedAt: Date(),
                eventCount: ingestEvents.count,
                persistResult: result,
                errorMessage: nil
            )
            
            context.logger.info("IngestNWSAlertsJob finished")
        } catch {
            await recordIngestSweepRun(
                context: context,
                payload: payload,
                status: .failed,
                startedAt: startedAt,
                completedAt: Date(),
                eventCount: nil,
                persistResult: nil,
                errorMessage: String(reflecting: error)
            )
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

extension IngestNWSAlertsJob {
    func startEventCleanup(on database: any Database, asOf: Date, logger: Logger) async throws -> CleanupResult {
        let expired = ArcusSeriesModel.query(on: database)
            .group(.and) { group in
                group.filter(\.$state == EventState.active.rawValue)
                group.filter(\.$expires <= asOf)
                group.group(.or) { terminalDate in
                    terminalDate.filter(\.$ends >= asOf)
                    terminalDate.filter(\.$ends == nil)
                }
            }
        let expiredCount = try await expired.count()

        try await expired
            .set(\.$state, to: "expired")
            .update()

        let ended = ArcusSeriesModel.query(on: database)
            .group(.and) { group in
                group.group(.or) { states in
                    states.filter(\.$state == EventState.active.rawValue)
                    states.filter(\.$state == EventState.expired.rawValue)
                }
                group.filter(\.$ends < asOf)
            }
        let endedCount = try await ended.count()

        try await ended
            .set(\.$state, to: "ended")
            .update()

        return .init(expiredCount: expiredCount, endedCount: endedCount)
    }
}

private extension IngestNWSAlertsJob {
    func recordIngestSweepRun(
        context: QueueContext,
        payload: Payload,
        status: IngestSweepRunStatus,
        startedAt: Date,
        completedAt: Date,
        eventCount: Int?,
        persistResult: PersistResult?,
        errorMessage: String?
    ) async {
        let run = IngestSweepRunModel(
            source: payload.source.rawValue,
            fixtureName: payload.fixtureName,
            runLabel: payload.runLabel,
            status: status,
            startedAt: startedAt,
            completedAt: completedAt,
            eventCount: eventCount,
            newSeriesCount: persistResult?.newSeriesCreated,
            newRevisionCount: persistResult?.newRevisionsCreated,
            targetOutboxQueuedCount: persistResult?.targetOutboxQueued,
            notificationOutboxQueuedCount: persistResult?.notificationOutboxQueued,
            errorMessage: errorMessage
        )

        do {
            try await run.create(on: context.application.db)
        } catch {
            context.logger.warning(
                "Failed to record ingest sweep run.",
                metadata: [
                    "status": .string(status.rawValue),
                    "error": .string(String(reflecting: error))
                ]
            )
        }
    }

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
}

private extension IngestNWSAlertsJob {
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

}
