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
        let now = Date()
        let pendingRows = try await ArcusNotificationOutboxModel.query(on: context.application.db)
            .group(.and) { group in
                group.filter(\.$state == "ready")
                     .filter(\.$mode == mode) // Lock this dispatcher to only send ready ugc notification msgs
                     .filter(\.$availableAt <= now)
            }
            .sort(\.$availableAt, .ascending)
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
                guard let reason = NotificationReason(rawValue: row.reason) else {
                    throw ArcusEventModelError.invalidEnum(field: "reason", value: row.reason)
                }
                
                let pl: NotificationSendJobPayload = .init(
                    seriesId: row.$series.id,
                    revisionUrn: row.revisionUrn,
                    mode: mode,
                    reason: reason
                )
                
                try await sendQueue.dispatch(NotificationSendJob.self, pl)
                row.availableAt = Date()
                row.lastError = nil
                row.attempts += 1
                row.state = "done" // Mark as done since we've sent it to the queue
                
                try await row.update(on: context.application.db)
                dispatched += 1
            } catch {
                failed += 1
                row.attempts += 1
                row.lastError = String(reflecting: error)
                
                if row.attempts >= 3 {
                    row.state = "dead" // Mark is as dead after 3 retries
                }
                
                try? await row.update(on: context.application.db)

                context.logger.error(
                    "Failed to dispatch notifcation job from outbox.",
                    metadata: [
                        "outboxId": .string(row.id?.uuidString ?? "unknown"),
                        "revisionUrn": .string(row.revisionUrn),
                        "error": .string(String(reflecting: error)),
                        "mode": .string(mode)
                    ]
                )
            }
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
                    let previousState = existing.state
                    let shouldResetForDispatch = existing.state != "ready" || existing.availableAt > .now || existing.reason != reason.rawValue

                    if shouldResetForDispatch {
                        existing.state = "ready"
                        existing.reason = reason.rawValue
                        existing.attempts = 0
                        existing.lastError = nil
                        existing.availableAt = .now
                        try await existing.update(on: database)

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
}
