//
//  DispatchAgent.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/24/26.
//

import Fluent
import FluentSQL
import Foundation
import Queues

public struct DispatchDrainResult {
    let dispatched: Int
    let failed: Int
}

public struct DispatchAgent {
    public static func dispatchPendingNotificationJobs(
        context: QueueContext,
        mode: String,
        limit: Int = 250
    ) async throws -> DispatchDrainResult {
        let store = NotificationDispatchOutboxStore()
        let pendingRows = try await store.claim(mode: mode, limit: limit, on: context.application.db)

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
                guard let reason = NotificationReason(rawValue: row.reason) else {
                    throw ArcusEventModelError.invalidEnum(field: "reason", value: row.reason)
                }
                
                let pl: NotificationSendJobPayload = .init(
                    seriesId: row.seriesId,
                    revisionUrn: row.revisionUrn,
                    mode: mode,
                    reason: reason
                )
                
                try await sendQueue.dispatch(
                    NotificationSendJob.self,
                    pl,
                    maxRetryCount: NotificationSendJob.maximumRetryCount
                )
            } catch {
                failed += 1
                _ = try await store.complete(row, error: String(reflecting: error), on: context.application.db)

                context.logger.error(
                    "Failed to dispatch notifcation job from outbox.",
                    metadata: [
                        "outboxId": .string(row.id.uuidString),
                        "revisionUrn": .string(row.revisionUrn),
                        "error": .string(String(reflecting: error)),
                        "mode": .string(mode)
                    ]
                )
                continue
            }
            // Persistence failure after enqueue leaves the lease for recovery;
            // it must not count a second, failed queue-handoff attempt.
            _ = try await store.complete(row, on: context.application.db)
            dispatched += 1
        }

        return .init(dispatched: dispatched, failed: failed)
    }
    
    public static func enqueueNotificationDispatchOutbox(
        revisionUrn: String,
        seriesId: UUID,
        reason: NotificationReason,
        mode: NotificationTargetMode,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        let existing = try await ArcusNotificationOutboxModel.query(on: database)
            .group(.and) { group in
                group.filter(\.$series.$id == seriesId)
                    .filter(\.$revisionUrn == revisionUrn)
                    .filter(\.$mode == mode.rawValue)
            }
            .first()

        if let existing {
            return try await handleExistingNotificationDispatchOutbox(
                existing,
                revisionUrn: revisionUrn,
                reason: reason,
                mode: mode,
                on: database,
                logger: logger
            )
        }

        let outboxRecord = ArcusNotificationOutboxModel(
            series: seriesId,
            revisionUrn: revisionUrn,
            mode: mode.rawValue,
            reason: reason.rawValue,
            state: "ready",
            attempts: 0,
            availableAt: .now
        )

        do {
            try await outboxRecord.create(on: database)
            return true
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                let existing = try await ArcusNotificationOutboxModel.query(on: database)
                    .group(.and) { group in
                        group.filter(\.$series.$id == seriesId)
                            .filter(\.$revisionUrn == revisionUrn)
                            .filter(\.$mode == mode.rawValue)
                    }
                    .first()

                if let existing {
                    return try await handleExistingNotificationDispatchOutbox(
                        existing,
                        revisionUrn: revisionUrn,
                        reason: reason,
                        mode: mode,
                        on: database,
                        logger: logger
                    )
                }

                logger.debug(
                    "Notification dispatch already queued for revision.",
                    metadata: [
                        "revisionUrn": .string(revisionUrn),
                        "mode": .string(mode.rawValue)
                    ]
                )
                return false
            }

            throw error
        }
    }

    static func handleExistingNotificationDispatchOutbox(
        _ existing: ArcusNotificationOutboxModel,
        revisionUrn: String,
        reason: NotificationReason,
        mode: NotificationTargetMode,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        let previousState = existing.state

        if existing.state == "done" {
            logger.debug(
                "Notification dispatch already completed for revision.",
                metadata: [
                    "revisionUrn": .string(revisionUrn),
                    "mode": .string(mode.rawValue),
                    "previousState": .string(previousState)
                ]
            )
            return false
        }

        let shouldResetForDispatch = try await NotificationDispatchOutboxStore().resetForReplay(
            id: existing.requireID(), reason: reason, on: database
        )

        if shouldResetForDispatch {
            logger.info(
                "Notification dispatch re-queued for revision.",
                metadata: [
                    "revisionUrn": .string(revisionUrn),
                    "mode": .string(mode.rawValue),
                    "previousState": .string(previousState)
                ]
            )
            return true
        }

        logger.debug(
            "Notification dispatch already queued for revision.",
            metadata: [
                "revisionUrn": .string(revisionUrn),
                "mode": .string(mode.rawValue)
            ]
        )
        return false
    }
}
