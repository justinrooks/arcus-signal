import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

struct MesoNotificationSendPayload: Codable, Sendable {
    let issueYear: Int
    let number: Int
    let deliveryAttemptID: UUID

    init(issueYear: Int, number: Int, deliveryAttemptID: UUID = UUID()) {
        self.issueYear = issueYear
        self.number = number
        self.deliveryAttemptID = deliveryAttemptID
    }

    var subject: NotificationSubject { .spcMeso(issueYear: issueYear, number: number) }
    var retryOwnerID: String { deliveryAttemptID.uuidString }
}

struct MesoNotificationSendJob: AsyncJob {
    typealias Payload = MesoNotificationSendPayload
    static let maximumRetryCount = 3
    private let sender: any NotificationSender
    private let store = NotificationDeliveryStore()

    init(sender: any NotificationSender = APNsClient()) { self.sender = sender }

    func nextRetryIn(attempt: Int) -> Int {
        NotificationSendRetryPolicy().delaySeconds(forAttempt: attempt)
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        let app = context.application
        let db = app.db
        let now = Date()
        guard app.mesoNotificationsEnabled else {
            try await failOwnedRetries(payload, code: "MesoRolloutDisabled", on: db)
            return
        }
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard let discussion = try await loadMesos(sql: sql, productID: payload.subject.productID, h3: nil, evaluatedAt: now).first,
              discussion.issueYear == payload.issueYear, discussion.number == payload.number,
              discussion.validStart <= now, discussion.validEnd > now else {
            try await failOwnedRetries(payload, code: "RetryIneligibleInactiveMeso", on: db)
            return
        }
        let retries = try await store.loadRetryingMesoDeliveries(
            issueYear: payload.issueYear, number: payload.number, retryOwnerID: payload.retryOwnerID, on: db
        )
        let failures = try await queueFailureCount(context)
        if retries.isEmpty {
            guard failures == 0,
                  !(try await store.hasMesoRetryInFlight(issueYear: payload.issueYear, number: payload.number,
                                                      retryOwnerID: payload.retryOwnerID, on: db)) else { return }
        }
        let matching = try await NotificationCandidateStore().loadMesoCandidates(
            productID: payload.subject.productID, evaluatedAt: now, on: db
        )
        let eligible = matching.filter {
            LocationFreshnessPolicy().decide(capturedAt: $0.capturedAt, locationAuth: $0.locationAuth, now: now).state != .stale
        }
        let retryByInstallation = Dictionary(uniqueKeysWithValues: retries.map { ($0.installationID, $0) })
        let candidates = retries.isEmpty ? eligible : eligible.filter { retryByInstallation[$0.id] != nil }
        let eligibleIDs = Set(candidates.map(\.id))
        for retry in retries where !eligibleIDs.contains(retry.installationID) {
            _ = try await store.completeRetryingMesoFailure(
                retry, issueYear: payload.issueYear, number: payload.number, retryOwnerID: payload.retryOwnerID,
                apnsErrorCode: "RetryIneligibleMesoCandidate", on: db
            )
        }
        guard let customData = HotAlertAPNsPayload(productKind: .mesoscaleDiscussion, resourceID: payload.subject.productID) else {
            throw Abort(.internalServerError, reason: "Invalid meso APNs identity")
        }
        var retryableCount = 0
        for candidate in candidates {
            // Recheck the local runtime gate before acquiring delivery authority.
            guard app.mesoNotificationsEnabled else { break }
            let freshness = LocationFreshnessPolicy().decide(
                capturedAt: candidate.capturedAt, locationAuth: candidate.locationAuth, now: Date()
            )
            guard freshness.state != .stale else { continue }
            let retry = retryByInstallation[candidate.id]
            let claim: LedgerClaimResult
            if let retry {
                claim = try await store.reclaimRetryingMeso(
                    retry, issueYear: payload.issueYear, number: payload.number,
                    retryOwnerID: payload.retryOwnerID, freshnessState: freshness.state, on: db
                )
            } else {
                claim = try await store.claimMeso(
                    installationID: candidate.id, issueYear: payload.issueYear, number: payload.number,
                    mode: .h3, reason: .new, freshnessState: freshness.state,
                    retryOwnerID: payload.retryOwnerID, origin: .alertDriven, on: db
                )
            }
            guard claim.inserted else { continue }
            guard app.mesoNotificationsEnabled, discussion.validEnd > Date() else {
                try await store.completeFailed(claimID: claim.id, apnsErrorCode: "MesoDeliveryDisabledOrExpired", on: db)
                continue
            }
            let details = MesoNotificationComposer().buildPreviewNotification(for: discussion, placeLabel: candidate.countyLabel)
            let startedAt = retry == nil ? Date() : nil
            do {
                try await sender.sendNotification(
                    app: app, with: details, hotAlertPayload: customData, to: candidate.apnsToken,
                    environment: APNsEnvironment(rawValue: candidate.apnsEnvironment) ?? .prod
                )
            } catch {
                switch APNsDeliveryFailureClassifier().classify(error) {
                case .retryable(let code):
                    try await store.markRetrying(claimID: claim.id, retryOwnerID: payload.retryOwnerID,
                        retryGeneration: claim.retryGeneration, apnsErrorCode: code, firstAttemptStartedAt: startedAt, on: db)
                    retryableCount += 1
                case .terminal(let code):
                    try await store.completeFailed(claimID: claim.id, apnsErrorCode: code, firstAttemptStartedAt: startedAt, on: db)
                case .invalidToken(let code):
                    try await store.completeInvalidTokenFailure(claimID: claim.id, installationID: candidate.id,
                        failedToken: candidate.apnsToken, apnsErrorCode: code, firstAttemptStartedAt: startedAt, on: db)
                }
                continue
            }
            try await store.completeSent(claimID: claim.id, firstAttemptStartedAt: startedAt, on: db)
        }
        if retryableCount > 0 { throw NotificationDeliveryRetryableError.retryableFailures(retryableCount) }
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        try await failOwnedRetries(payload, code: "RetryExhausted", on: context.application.db)
        context.logger.error("Meso notification send exhausted retries.")
    }

    private func failOwnedRetries(_ payload: Payload, code: String, on db: any Database) async throws {
        _ = try await store.failRetryingMesoDeliveries(issueYear: payload.issueYear, number: payload.number,
            retryOwnerID: payload.retryOwnerID, apnsErrorCode: code, on: db)
    }

    private func queueFailureCount(_ context: QueueContext) async throws -> Int {
        guard case let .string(jobID)? = context.logger[metadataKey: "job_id"] else { return 0 }
        let data = try await context.queues(context.queueName).get(JobIdentifier(string: jobID)).get()
        return data.attempts ?? 0
    }
}
