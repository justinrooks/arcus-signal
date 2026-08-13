import Fluent
import Queues
import Vapor

struct DispatchPresenceReconciliationScheduledJob: AsyncScheduledJob {
    static let batchLimit = 100

    private let store: PresenceReconciliationOutboxStore

    init(store: PresenceReconciliationOutboxStore = .init()) {
        self.store = store
    }

    func run(context: QueueContext) async throws {
        try await dispatchReady(context: context, on: context.application.db)
    }

    func dispatchReady(
        context: QueueContext,
        on database: any Database
    ) async throws {
        let intents = try await store.readyIntents(
            availableThrough: .now,
            limit: Self.batchLimit,
            on: database
        )

        context.logger.info(
            "Dispatching ready presence reconciliation intents.",
            metadata: ["intentCount": .stringConvertible(intents.count)]
        )

        for intent in intents {
            guard let intentId = intent.id else {
                context.logger.error("Ready presence reconciliation intent has no identifier.")
                continue
            }

            await context.application.presenceReconciliationHandoff.handoff(
                .init(
                    intentId: intentId,
                    installationId: intent.$installation.id,
                    triggerCategory: intent.triggerCategory,
                    priorAttemptCount: intent.attemptCount
                ),
                on: context.application,
                database: database,
                logger: context.logger
            )
        }
    }
}
