import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

struct MesoNotificationSendPayload: Codable, Sendable {
    let issueYear: Int
    let number: Int
    let installationID: UUID?
    let deliveryAttemptID: UUID

    init(issueYear: Int, number: Int, installationID: UUID? = nil, deliveryAttemptID: UUID = UUID()) {
        self.issueYear = issueYear
        self.number = number
        self.installationID = installationID
        self.deliveryAttemptID = deliveryAttemptID
    }

    var subject: NotificationSubject { .spcMeso(issueYear: issueYear, number: number) }
    var retryOwnerID: String { deliveryAttemptID.uuidString }
}

private struct MesoDispatchSummary {
    var candidateResolutionReached = false
    var candidateCount = 0
    var claimedCount = 0
    var sentCount = 0
    var failedCount = 0
    var retryableFailureCount = 0
    var noOpReason: NotificationSendNoOpReason?
}

struct MesoNotificationSendJob: AsyncJob {
    typealias Payload = MesoNotificationSendPayload
    static let maximumRetryCount = 3
    private let sender: any NotificationSender
    private let store = NotificationDeliveryStore()
    private let loadDiscussion: @Sendable (any SQLDatabase, String, Date) async throws -> MesoscaleDiscussionPayload?

    init(
        sender: any NotificationSender = APNsClient(),
        loadDiscussion: @escaping @Sendable (any SQLDatabase, String, Date) async throws -> MesoscaleDiscussionPayload? = { sql, id, now in
            try await loadMesos(sql: sql, productID: id, h3: nil, evaluatedAt: now).first
        }
    ) {
        self.sender = sender
        self.loadDiscussion = loadDiscussion
    }

    func nextRetryIn(attempt: Int) -> Int {
        NotificationSendRetryPolicy().delaySeconds(forAttempt: attempt)
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        let app = context.application
        let db = app.db
        let now = Date()
        guard app.mesoNotificationsEnabled else {
            let failedCount = try await failOwnedRetries(payload, code: "MesoRolloutDisabled", on: db)
            await recordAttempt(payload, summary: .init(
                failedCount: failedCount,
                noOpReason: failedCount == 0 ? .rolloutDisabled : nil
            ), using: context)
            return
        }
        guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
        guard let discussion = try await loadDiscussion(sql, payload.subject.productID, now),
              discussion.issueYear == payload.issueYear, discussion.number == payload.number,
              discussion.validStart <= now, discussion.validEnd > now else {
            let failedCount = try await failOwnedRetries(payload, code: "RetryIneligibleInactiveMeso", on: db)
            await recordAttempt(payload, summary: .init(
                failedCount: failedCount,
                noOpReason: failedCount == 0 ? .inactiveOrExpiredSeries : nil
            ), using: context)
            return
        }
        let retries = try await store.loadRetryingMesoDeliveries(
            issueYear: payload.issueYear, number: payload.number, retryOwnerID: payload.retryOwnerID, on: db
        )
        if retries.isEmpty {
            // Queue attempts alone cannot prove that delivery began. Recover
            // pre-claim failures, but never rediscover after any owned claim.
            guard !(try await store.hasMesoClaims(issueYear: payload.issueYear, number: payload.number,
                                                 retryOwnerID: payload.retryOwnerID, on: db)) else {
                await recordAttempt(payload, summary: .init(noOpReason: .allCandidatesPreviouslyClaimed), using: context)
                return
            }
        }
        let matching = try await NotificationCandidateStore().loadMesoCandidates(
            productID: payload.subject.productID, installationID: payload.installationID, evaluatedAt: now, on: db
        )
        let eligible = matching.filter {
            LocationFreshnessPolicy().decide(capturedAt: $0.capturedAt, locationAuth: $0.locationAuth, now: now).state != .stale
        }
        let retryByInstallation = Dictionary(uniqueKeysWithValues: retries.map { ($0.installationID, $0) })
        let candidates = retries.isEmpty ? eligible : eligible.filter { retryByInstallation[$0.id] != nil }
        var summary = MesoDispatchSummary(
            candidateResolutionReached: true,
            candidateCount: candidates.count
        )
        let eligibleIDs = Set(candidates.map(\.id))
        if matching.isEmpty {
            await saveDebugSnapshot(
                subject: payload.subject,
                installationID: nil,
                notificationLedgerID: nil,
                recordKind: .previewNoCandidates,
                details: MesoNotificationComposer().buildPreviewNotification(for: discussion),
                using: context
            )
        }
        for retry in retries where !eligibleIDs.contains(retry.installationID) {
            let completed = try await store.completeRetryingMesoFailure(
                retry, issueYear: payload.issueYear, number: payload.number, retryOwnerID: payload.retryOwnerID,
                apnsErrorCode: "RetryIneligibleMesoCandidate", on: db
            )
            if completed { summary.failedCount += 1 }
        }
        guard let customData = HotAlertAPNsPayload(productKind: .mesoscaleDiscussion, resourceID: payload.subject.productID) else {
            throw Abort(.internalServerError, reason: "Invalid meso APNs identity")
        }
        var staleAtSendCount = 0
        for candidate in candidates {
            // Recheck the local runtime gate before acquiring delivery authority.
            guard app.mesoNotificationsEnabled else {
                if summary.sentCount == 0 && summary.failedCount == 0 && summary.retryableFailureCount == 0 {
                    summary.noOpReason = .rolloutDisabled
                }
                break
            }
            let freshness = LocationFreshnessPolicy().decide(
                capturedAt: candidate.capturedAt, locationAuth: candidate.locationAuth, now: Date()
            )
            guard freshness.state != .stale else {
                staleAtSendCount += 1
                continue
            }
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
                    retryOwnerID: payload.retryOwnerID, origin: payload.installationID == nil ? .alertDriven : .presenceReconciliation, on: db
                )
            }
            guard claim.inserted else { continue }
            summary.claimedCount += 1
            guard app.mesoNotificationsEnabled, discussion.validEnd > Date() else {
                try await store.completeFailed(claimID: claim.id, apnsErrorCode: "MesoDeliveryDisabledOrExpired", on: db)
                summary.failedCount += 1
                continue
            }
            let details = MesoNotificationComposer().buildPreviewNotification(for: discussion, placeLabel: candidate.countyLabel)
            await saveDebugSnapshot(
                subject: payload.subject,
                installationID: candidate.id,
                notificationLedgerID: claim.id,
                recordKind: .candidate,
                details: details,
                using: context
            )
            let consentAllowsDelivery: Bool
            do {
                consentAllowsDelivery = try await NotificationCandidateStore().acceptedConsentAllowsDelivery(candidate, meso: true, on: db)
            } catch {
                // A failed pre-send read must remain retryable; never strand a claimed row.
                try await store.markRetrying(claimID: claim.id, retryOwnerID: payload.retryOwnerID,
                    retryGeneration: claim.retryGeneration, apnsErrorCode: "ConsentEligibilityReadFailed", on: db)
                summary.retryableFailureCount += 1
                continue
            }
            guard consentAllowsDelivery else {
                try await store.completeFailed(claimID: claim.id, apnsErrorCode: "ConsentRevokedBeforeSend", on: db)
                summary.failedCount += 1
                continue
            }
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
                    summary.retryableFailureCount += 1
                case .terminal(let code):
                    try await store.completeFailed(claimID: claim.id, apnsErrorCode: code, firstAttemptStartedAt: startedAt, on: db)
                    summary.failedCount += 1
                case .invalidToken(let code):
                    try await store.completeInvalidTokenFailure(claimID: claim.id, installationID: candidate.id,
                        failedToken: candidate.apnsToken, apnsErrorCode: code, firstAttemptStartedAt: startedAt, on: db)
                    summary.failedCount += 1
                }
                continue
            }
            try await store.completeSent(claimID: claim.id, firstAttemptStartedAt: startedAt, on: db)
            summary.sentCount += 1
        }
        if summary.noOpReason == nil && summary.sentCount == 0 && summary.failedCount == 0 && summary.retryableFailureCount == 0 {
            if candidates.isEmpty {
                summary.noOpReason = matching.isEmpty ? .zeroCandidates : .allCandidatesStaleLocation
            } else if staleAtSendCount == candidates.count {
                summary.noOpReason = .allCandidatesStaleLocation
            } else {
                summary.noOpReason = .allCandidatesPreviouslyClaimed
            }
        }
        await recordAttempt(payload, summary: summary, using: context)
        if summary.retryableFailureCount > 0 {
            throw NotificationDeliveryRetryableError.retryableFailures(summary.retryableFailureCount)
        }
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        _ = try await failOwnedRetries(payload, code: "RetryExhausted", on: context.application.db)
        context.logger.error("Meso notification send exhausted retries.")
    }

    private func failOwnedRetries(_ payload: Payload, code: String, on db: any Database) async throws -> Int {
        try await store.failRetryingMesoDeliveries(issueYear: payload.issueYear, number: payload.number,
            retryOwnerID: payload.retryOwnerID, apnsErrorCode: code, on: db)
    }

    private func recordAttempt(_ payload: Payload, summary: MesoDispatchSummary, using context: QueueContext) async {
        let outcome: NotificationSendAttemptOutcome
        if summary.noOpReason != nil {
            outcome = .noOp
        } else if summary.retryableFailureCount > 0 {
            outcome = .retrying
        } else if summary.sentCount > 0 {
            outcome = .delivered
        } else {
            outcome = .failed
        }
        let attempt = NotificationSendAttemptModel(
            seriesID: nil,
            revisionUrn: payload.subject.revisionID,
            mode: .h3,
            reason: .new,
            outcome: outcome,
            noOpReason: summary.noOpReason,
            candidateResolutionReached: summary.candidateResolutionReached,
            candidateCount: summary.candidateCount,
            claimedCount: summary.claimedCount,
            sentCount: summary.sentCount,
            failedCount: summary.failedCount,
            subject: payload.subject
        )
        do {
            try await attempt.create(on: context.application.db)
        } catch {
            context.logger.warning("Failed to record meso notification attempt.", metadata: [
                "subject_id": .string(payload.subject.productID),
                "error": .string(String(reflecting: error))
            ])
        }
    }

    private func saveDebugSnapshot(
        subject: NotificationSubject,
        installationID: UUID?,
        notificationLedgerID: UUID?,
        recordKind: NotificationDebugRecordKind,
        details: AlertDetails,
        using context: QueueContext
    ) async {
        let snapshot = NotificationDebugModel(
            seriesID: nil,
            installationID: installationID,
            notificationLedgerID: notificationLedgerID,
            revisionUrn: subject.revisionID,
            mode: NotificationTargetMode.h3.rawValue,
            reason: NotificationReason.new.rawValue,
            recordKind: recordKind,
            title: details.title,
            subtitle: details.subTitle,
            body: details.body,
            subject: subject
        )
        do {
            try await snapshot.create(on: context.application.db)
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                context.logger.debug("Meso notification debug snapshot already exists.")
                return
            }
            context.logger.warning("Failed to save meso notification debug snapshot.", metadata: [
                "subject_id": .string(subject.productID),
                "record_kind": .string(recordKind.rawValue),
                "error": .string(String(reflecting: error))
            ])
        }
    }

}
