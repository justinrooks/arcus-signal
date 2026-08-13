import Fluent
import Foundation
import Logging
import Queues
import Vapor

struct ReconcileInstallationAlertsJobPayload: Codable, Sendable {
    let intentId: UUID
    let installationId: UUID
    let triggerCategory: PresenceReconciliationTriggerCategory
}

struct PresenceReconciliationHandoffRequest: Sendable {
    let intentId: UUID
    let installationId: UUID
    let triggerCategory: PresenceReconciliationTriggerCategory
    let priorAttemptCount: Int
}

protocol ReconcileInstallationAlertsJobDispatching: Sendable {
    func dispatch(
        _ payload: ReconcileInstallationAlertsJobPayload,
        on application: Application
    ) async throws
}

struct DefaultReconcileInstallationAlertsJobDispatcher: ReconcileInstallationAlertsJobDispatching {
    func dispatch(
        _ payload: ReconcileInstallationAlertsJobPayload,
        on application: Application
    ) async throws {
        try await application.queues
            .queue(ArcusQueueLane.target.queueName)
            .dispatch(
                ReconcileInstallationAlertsJob.self,
                payload,
                maxRetryCount: ReconcileInstallationAlertsJob.maximumRetryCount
            )
    }
}

protocol PresenceReconciliationHandoffPerforming: Sendable {
    func handoff(
        _ request: PresenceReconciliationHandoffRequest,
        on application: Application,
        database: any Database,
        logger: Logger
    ) async
}

struct PresenceReconciliationHandoff: PresenceReconciliationHandoffPerforming {
    private static let retryDelays: [TimeInterval] = [60, 300, 900, 3_600]

    private let store: PresenceReconciliationOutboxStore
    private let dispatcher: any ReconcileInstallationAlertsJobDispatching

    init(
        store: PresenceReconciliationOutboxStore = .init(),
        dispatcher: any ReconcileInstallationAlertsJobDispatching = DefaultReconcileInstallationAlertsJobDispatcher()
    ) {
        self.store = store
        self.dispatcher = dispatcher
    }

    func handoff(
        _ request: PresenceReconciliationHandoffRequest,
        on application: Application,
        database: any Database,
        logger: Logger
    ) async {
        let attempt = request.priorAttemptCount + 1
        let metadata = metadata(for: request, attempt: attempt)

        do {
            try await dispatcher.dispatch(
                .init(
                    intentId: request.intentId,
                    installationId: request.installationId,
                    triggerCategory: request.triggerCategory
                ),
                on: application
            )
            let updated = try await store.recordQueueHandoffSuccess(
                intentID: request.intentId,
                on: database
            )
            logger.info(
                "Presence reconciliation queue handoff succeeded.",
                metadata: metadata.merging([
                    "outboxUpdated": .stringConvertible(updated)
                ]) { _, new in new }
            )
        } catch {
            let errorType = String(describing: type(of: error))
            let nextAvailableAt = Date().addingTimeInterval(retryDelay(after: request.priorAttemptCount))

            do {
                let updated = try await store.recordQueueHandoffFailure(
                    intentID: request.intentId,
                    error: errorType,
                    nextAvailableAt: nextAvailableAt,
                    on: database
                )
                logger.error(
                    "Presence reconciliation queue handoff failed; durable intent remains ready.",
                    metadata: metadata.merging([
                        "errorType": .string(errorType),
                        "nextAvailableAt": .string(nextAvailableAt.ISO8601Format()),
                        "outboxUpdated": .stringConvertible(updated)
                    ]) { _, new in new }
                )
            } catch {
                logger.error(
                    "Presence reconciliation queue handoff and fallback update failed.",
                    metadata: metadata.merging([
                        "dispatchErrorType": .string(errorType),
                        "fallbackErrorType": .string(String(describing: type(of: error)))
                    ]) { _, new in new }
                )
            }
        }
    }

    private func retryDelay(after priorAttemptCount: Int) -> TimeInterval {
        Self.retryDelays[min(max(0, priorAttemptCount), Self.retryDelays.count - 1)]
    }

    private func metadata(
        for request: PresenceReconciliationHandoffRequest,
        attempt: Int
    ) -> Logger.Metadata {
        [
            "intentId": .string(request.intentId.uuidString),
            "installationId": .string(request.installationId.uuidString),
            "trigger": .string(request.triggerCategory.rawValue),
            "handoffAttempt": .stringConvertible(attempt)
        ]
    }
}

struct ReconcileInstallationAlertsJob: AsyncJob {
    typealias Payload = ReconcileInstallationAlertsJobPayload

    static let retryDelaysSeconds = [15, 60, 300]
    static var maximumRetryCount: Int { retryDelaysSeconds.count }

    private let candidateStore: NotificationCandidateStore

    init(candidateStore: NotificationCandidateStore = .init()) {
        self.candidateStore = candidateStore
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        try await reconcile(context, payload, on: context.application.db)
    }

    func reconcile(
        _ context: QueueContext,
        _ payload: Payload,
        on database: any Database
    ) async throws {
        try Task.checkCancellation()

        let metadata = metadata(for: payload)
        context.logger.info("Installation alert reconciliation started.", metadata: metadata)

        let installation = try await DeviceInstallationModel.find(
            payload.installationId,
            on: database
        )
        let presence = try await DevicePresenceModel.find(
            payload.installationId,
            on: database
        )
        guard let currentState = PresenceReconciliationState(
            installation: installation,
            presence: presence
        ) else {
            context.logger.info(
                "Installation alert reconciliation stopped because authoritative state is missing.",
                metadata: metadata
            )
            return
        }

        let evaluatedAt = Date()
        guard PresenceReconciliationTrigger.isUsable(currentState, now: evaluatedAt) else {
            context.logger.info(
                "Installation alert reconciliation stopped because authoritative state is unusable.",
                metadata: metadata
            )
            return
        }

        var matchCount = 0
        var dispatchedCount = 0
        do {
            let matches = try await candidateStore.loadMatchingActiveAlerts(
                for: payload.installationId,
                evaluatedAt: evaluatedAt,
                on: database
            )
            matchCount = matches.count

            let sendQueue = context.application.queues.queue(ArcusQueueLane.send.queueName)
            for match in matches {
                try Task.checkCancellation()
                try await sendQueue.dispatch(
                    NotificationSendJob.self,
                    .init(
                        seriesId: match.seriesId,
                        revisionUrn: match.revisionUrn,
                        mode: match.mode,
                        reason: match.reason,
                        installationId: payload.installationId
                    )
                )
                dispatchedCount += 1
            }

            context.logger.info(
                "Installation alert reconciliation completed.",
                metadata: metadata.merging([
                    "matchCount": .stringConvertible(matchCount),
                    "dispatchCount": .stringConvertible(dispatchedCount)
                ]) { _, new in new }
            )
        } catch {
            context.logger.error(
                "Installation alert reconciliation attempt failed.",
                metadata: metadata.merging([
                    "matchCount": .stringConvertible(matchCount),
                    "dispatchCount": .stringConvertible(dispatchedCount),
                    "errorType": .string(String(describing: type(of: error)))
                ]) { _, new in new }
            )
            throw error
        }
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "Installation alert reconciliation exhausted retries.",
            metadata: metadata(for: payload).merging([
                "maximumRetryCount": .stringConvertible(Self.maximumRetryCount),
                "errorType": .string(String(describing: type(of: error)))
            ]) { _, new in new }
        )
    }

    func nextRetryIn(attempt: Int) -> Int {
        Self.retryDelaysSeconds[min(max(0, attempt - 1), Self.retryDelaysSeconds.count - 1)]
    }

    private func metadata(for payload: Payload) -> Logger.Metadata {
        [
            "intentId": .string(payload.intentId.uuidString),
            "installationId": .string(payload.installationId.uuidString),
            "trigger": .string(payload.triggerCategory.rawValue)
        ]
    }
}

extension Application {
    var presenceReconciliationHandoff: any PresenceReconciliationHandoffPerforming {
        get { storage[PresenceReconciliationHandoffKey.self] ?? PresenceReconciliationHandoff() }
        set { storage[PresenceReconciliationHandoffKey.self] = newValue }
    }
}

private struct PresenceReconciliationHandoffKey: StorageKey {
    typealias Value = any PresenceReconciliationHandoffPerforming
}
