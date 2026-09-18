//
//  NotificationSendJob.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/3/26.
//

import ArcusCore
import APNSCore
import Fluent
import Foundation
import Queues
import Vapor

struct DispatchNotificationsResult {
    let candidateResolutionReached: Bool
    let candidateCount: Int
    let staleMissedCount: Int
    let claimedCount: Int
    let sentCount: Int
    let failedCount: Int
    let retryableFailureCount: Int
    let noOpReason: NotificationSendNoOpReason?
}

struct NotificationSendRetryPolicy: Sendable, Equatable {
    static let defaultDelaysSeconds = [30, 120, 300]

    let delaysSeconds: [Int]

    init(delaysSeconds: [Int] = defaultDelaysSeconds) {
        self.delaysSeconds = delaysSeconds.isEmpty
            || delaysSeconds.count > Self.defaultDelaysSeconds.count
            || delaysSeconds.contains(where: { $0 <= 0 })
            ? Self.defaultDelaysSeconds
            : delaysSeconds
    }

    var maximumRetryCount: Int { delaysSeconds.count }

    func delaySeconds(forAttempt attempt: Int) -> Int {
        delaysSeconds[min(max(0, attempt - 1), delaysSeconds.count - 1)]
    }
}

enum NotificationDeliveryRetryableError: Error, Sendable {
    case retryableFailures(Int)
}

enum NotificationCandidateDeliveryDisposition: Sendable, Equatable {
    case deliver(LocationFreshnessDecision)
    case skipStale(LocationFreshnessDecision)
}

public enum NotificationTargetMode: String, Codable, Sendable {
    case h3
    case ugc
}

public enum NotificationReason: String, Codable, Sendable {
    case new
    case update
    case endedAllClear
    case cancelInError
}

public struct NotificationSendJobPayload: Codable, Sendable {
    let seriesId: UUID
    let revisionUrn: String
    let mode: NotificationTargetMode
    let reason: NotificationReason
    let installationId: UUID?
    let deliveryAttemptId: UUID?
    
    init(
        seriesId: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        installationId: UUID? = nil,
        deliveryAttemptId: UUID? = UUID()
    ) {
        self.seriesId = seriesId
        self.revisionUrn = revisionUrn
        self.mode = mode
        self.reason = reason
        self.installationId = installationId
        self.deliveryAttemptId = deliveryAttemptId
    }
}

public struct NotificationSendJob: AsyncJob {
    public typealias Payload = NotificationSendJobPayload
    static let retryPolicy = NotificationSendRetryPolicy()
    static var maximumRetryCount: Int { retryPolicy.maximumRetryCount }

    private let sender: any NotificationSender
    private let engine: NotificationEngine
    private let freshnessPolicy: LocationFreshnessPolicy
    private let missedDecisionStore: NotificationMissedDecisionStore
    private let candidateStore: NotificationCandidateStore
    private let deliveryStore: NotificationDeliveryStore
    private let failureClassifier: APNsDeliveryFailureClassifier

    public init() {
        self.sender = APNsClient()
        self.engine = NotificationEngine()
        self.freshnessPolicy = LocationFreshnessPolicy()
        self.missedDecisionStore = NotificationMissedDecisionStore()
        self.candidateStore = NotificationCandidateStore()
        self.deliveryStore = NotificationDeliveryStore()
        self.failureClassifier = APNsDeliveryFailureClassifier()
    }

    init(
        sender: any NotificationSender,
        engine: NotificationEngine = NotificationEngine(),
        freshnessPolicy: LocationFreshnessPolicy = LocationFreshnessPolicy(),
        missedDecisionStore: NotificationMissedDecisionStore = NotificationMissedDecisionStore(),
        candidateStore: NotificationCandidateStore = NotificationCandidateStore(),
        deliveryStore: NotificationDeliveryStore = NotificationDeliveryStore(),
        failureClassifier: APNsDeliveryFailureClassifier = APNsDeliveryFailureClassifier()
    ) {
        self.sender = sender
        self.engine = engine
        self.freshnessPolicy = freshnessPolicy
        self.missedDecisionStore = missedDecisionStore
        self.candidateStore = candidateStore
        self.deliveryStore = deliveryStore
        self.failureClassifier = failureClassifier
    }

    func deliveryDisposition(
        for candidate: NotificationCandidate,
        evaluatedAt: Date
    ) -> NotificationCandidateDeliveryDisposition {
        let freshness = freshnessPolicy.decide(
            capturedAt: candidate.capturedAt,
            locationAuth: candidate.locationAuth,
            now: evaluatedAt
        )
        switch freshness.state {
        case .stale:
            return .skipStale(freshness)
        case .fresh, .degraded:
            return .deliver(freshness)
        }
    }

    func deliveryNoOpReason(
        for series: ArcusSeriesModel,
        reason: NotificationReason,
        evaluatedAt: Date
    ) -> NotificationSendNoOpReason? {
        switch reason {
        case .endedAllClear, .cancelInError:
            return nil
        case .new, .update:
            break
        }

        guard series.state == EventState.active.rawValue,
              series.expires.map({ $0 > evaluatedAt }) ?? true,
              series.ends.map({ $0 > evaluatedAt }) ?? true else {
            return .inactiveOrExpiredSeries
        }

        return nil
    }
    
    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        let retryOwnerID = retryOwnerID(context: context, payload: payload)
        let queueFailureCount = try await queueFailureCount(context: context)
        context.logger.info(
            "NotificationSendJob started",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "revisionUrn": .string(payload.revisionUrn),
                "mode": .string("\(String.init(reflecting: payload.mode))"),
                "reason": .string("\(String.init(reflecting: payload.reason))")
            ]
        )
        let attemptedAt = Date()
        
        // Grab the associated series, revisions, & geometry
        let series = try await ArcusSeriesModel.query(on: context.application.db)
            .with(\.$geolocation)
            .with(\.$revisions)
            .group(.and) { group in
                group.filter(\.$id == payload.seriesId)
            }
            .first()
        
        guard let series, series.currentRevisionUrn == payload.revisionUrn else {
            let failedRetryCount = try await deliveryStore.failRetryingDeliveries(
                seriesID: payload.seriesId,
                revisionUrn: payload.revisionUrn,
                installationID: payload.installationId,
                retryOwnerID: retryOwnerID,
                apnsErrorCode: "RetryIneligibleStaleRevision",
                on: context.application.db
            )
            context.logger.warning(
                "Current revision urn doesn't match payload revision. No notification sent",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "currentRevUrn": .string(series?.currentRevisionUrn ?? "unknown"),
                    "revisionUrn": .string(payload.revisionUrn),
                    "mode": .string("\(String.init(reflecting: payload.mode))"),
                    "reason": .string("\(String.init(reflecting: payload.reason))")
                ]
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: .init(
                    candidateResolutionReached: false,
                    candidateCount: 0,
                    staleMissedCount: 0,
                    claimedCount: 0,
                    sentCount: 0,
                    failedCount: failedRetryCount,
                    retryableFailureCount: 0,
                    noOpReason: failedRetryCount == 0 ? .staleRevisionMismatch : nil
                )
            )
            return
        }

        if let noOpReason = deliveryNoOpReason(
            for: series,
            reason: payload.reason,
            evaluatedAt: Date()
        ) {
            context.logger.info(
                "Series is no longer eligible for notification delivery. No notification sent",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "state": .string(series.state),
                    "expires": .string(series.expires?.description ?? "none"),
                    "ends": .string(series.ends?.description ?? "none"),
                    "reason": .string(payload.reason.rawValue)
                ]
            )
            let failedRetryCount = try await deliveryStore.failRetryingDeliveries(
                seriesID: payload.seriesId,
                revisionUrn: payload.revisionUrn,
                installationID: payload.installationId,
                retryOwnerID: retryOwnerID,
                apnsErrorCode: "RetryIneligibleSeriesLifecycle",
                on: context.application.db
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: .init(
                    candidateResolutionReached: false,
                    candidateCount: 0,
                    staleMissedCount: 0,
                    claimedCount: 0,
                    sentCount: 0,
                    failedCount: failedRetryCount,
                    retryableFailureCount: 0,
                    noOpReason: failedRetryCount == 0 ? noOpReason : nil
                )
            )
            return
        }

        let presenceCutoff = attemptedAt.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)

        let retryingDeliveries = try await deliveryStore.loadRetryingDeliveries(
            seriesID: payload.seriesId,
            revisionUrn: payload.revisionUrn,
            installationID: payload.installationId,
            retryOwnerID: retryOwnerID,
            on: context.application.db
        )
        if !retryingDeliveries.isEmpty {
            let summary = try await dispatchRetryingNotifications(
                retryingDeliveries,
                with: payload,
                and: series,
                capturedAtOrAfter: presenceCutoff,
                retryOwnerID: retryOwnerID,
                using: context
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: summary
            )
            return
        }

        if try await deliveryStore.hasRetryInFlight(
            seriesID: payload.seriesId,
            revisionUrn: payload.revisionUrn,
            installationID: payload.installationId,
            retryOwnerID: retryOwnerID,
            on: context.application.db
        ) {
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: .init(
                    candidateResolutionReached: true,
                    candidateCount: 0,
                    staleMissedCount: 0,
                    claimedCount: 0,
                    sentCount: 0,
                    failedCount: 0,
                    retryableFailureCount: 0,
                    noOpReason: .allCandidatesPreviouslyClaimed
                )
            )
            return
        }

        if queueFailureCount > 0 {
            context.logger.info(
                "Queue retry has no owned retrying deliveries. No notification sent",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "retryOwnerId": .string(retryOwnerID),
                    "queueFailureCount": .stringConvertible(queueFailureCount)
                ]
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: .init(
                    candidateResolutionReached: false,
                    candidateCount: 0,
                    staleMissedCount: 0,
                    claimedCount: 0,
                    sentCount: 0,
                    failedCount: 0,
                    retryableFailureCount: 0,
                    noOpReason: .allCandidatesPreviouslyClaimed
                )
            )
            return
        }
        
        // if mode is h3 and we have cells
        // right now we aren't falling back to zones... but maybe we should?
        if payload.mode == .h3 {
            guard let geo = series.geolocation, geo.h3Cells.count > 0 else {
                context.logger.warning(
                    "Missing or incomplete geospacial detail for series. No notification sent",
                    metadata: [
                        "seriesId": .string(payload.seriesId.uuidString)
                    ]
                )
                try await finishAttempt(
                    context: context,
                    payload: payload,
                    attemptedAt: attemptedAt,
                    summary: .init(
                        candidateResolutionReached: false,
                        candidateCount: 0,
                        staleMissedCount: 0,
                        claimedCount: 0,
                        sentCount: 0,
                        failedCount: 0,
                        retryableFailureCount: 0,
                        noOpReason: .missingGeolocation
                    )
                )
                return
            }
            
            // Get our list of candidates
            let h3Candidates = try await candidateStore.loadH3Candidates(
                cells: geo.h3Cells,
                capturedAtOrAfter: presenceCutoff,
                installationId: payload.installationId,
                on: context.application.db
            )
            
            let summary = try await dispatchNotifications(
                to: h3Candidates,
                with: payload,
                and: series,
                retryOwnerID: retryOwnerID,
                using: context
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: summary
            )
        } else {
            // we only have 2 modes right now, so its ugc
            let ugcCandidates = try await candidateStore.loadUGCCandidates(
                ugcCodes: series.ugcCodes,
                capturedAtOrAfter: presenceCutoff,
                installationId: payload.installationId,
                on: context.application.db
            )

            let summary = try await dispatchNotifications(
                to: ugcCandidates,
                with: payload,
                and: series,
                retryOwnerID: retryOwnerID,
                using: context
            )
            try await finishAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: summary
            )
        }

        context.logger.info(
            "Notification processing complete",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "revisionUrn": .string(payload.revisionUrn),
                "mode": .string("\(String.init(reflecting: payload.mode))"),
                "reason": .string("\(String.init(reflecting: payload.reason))")
            ]
        )
    }
    
    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        let retryOwnerID = retryOwnerID(context: context, payload: payload)
        let failedCount = try await deliveryStore.failRetryingDeliveries(
            seriesID: payload.seriesId,
            revisionUrn: payload.revisionUrn,
            installationID: payload.installationId,
            retryOwnerID: retryOwnerID,
            apnsErrorCode: "RetryExhausted",
            on: context.application.db
        )
        context.logger.error(
            "NotificationSendJob exhausted retries.",
            metadata: [
                "errorType": .string(String(describing: type(of: error))),
                "failedDeliveryCount": .stringConvertible(failedCount),
                "maximumRetryCount": .stringConvertible(Self.maximumRetryCount)
            ]
        )
    }

    public func nextRetryIn(attempt: Int) -> Int {
        Self.retryPolicy.delaySeconds(forAttempt: attempt)
    }
}


extension NotificationSendJob {
    func retryOwnerID(
        context: QueueContext,
        payload: NotificationSendJobPayload
    ) -> String {
        if let deliveryAttemptID = payload.deliveryAttemptId {
            return deliveryAttemptID.uuidString
        }
        if case let .string(jobID)? = context.logger[metadataKey: "job_id"] {
            return jobID
        }
        return "legacy:\(payload.seriesId.uuidString):\(payload.revisionUrn):\(payload.installationId?.uuidString ?? "all")"
    }

    func queueFailureCount(context: QueueContext) async throws -> Int {
        guard case let .string(jobID)? = context.logger[metadataKey: "job_id"] else {
            return 0
        }
        let data = try await context.queues(context.queueName)
            .get(JobIdentifier(string: jobID))
            .get()
        return data.attempts ?? 0
    }

    func dispatchRetryingNotifications(
        _ deliveries: [NotificationRetryDelivery],
        with payload: NotificationSendJobPayload,
        and series: ArcusSeriesModel,
        capturedAtOrAfter cutoff: Date,
        retryOwnerID: String,
        using context: QueueContext
    ) async throws -> DispatchNotificationsResult {
        var candidates: [NotificationCandidate] = []
        var deliveriesByInstallation: [UUID: NotificationRetryDelivery] = [:]
        var ineligibleCount = 0

        for delivery in deliveries {
            let matches: [NotificationCandidate]
            switch payload.mode {
            case .h3:
                if let geolocation = series.geolocation, !geolocation.h3Cells.isEmpty {
                    matches = try await candidateStore.loadH3Candidates(
                        cells: geolocation.h3Cells,
                        capturedAtOrAfter: cutoff,
                        installationId: delivery.installationID,
                        on: context.application.db
                    )
                } else {
                    matches = []
                }
            case .ugc:
                matches = try await candidateStore.loadUGCCandidates(
                    ugcCodes: series.ugcCodes,
                    capturedAtOrAfter: cutoff,
                    installationId: delivery.installationID,
                    on: context.application.db
                )
            }

            guard let candidate = matches.first else {
                let terminalized = try await deliveryStore.completeRetryingFailure(
                    delivery,
                    seriesID: payload.seriesId,
                    revisionUrn: payload.revisionUrn,
                    retryOwnerID: retryOwnerID,
                    apnsErrorCode: "RetryIneligibleCandidate",
                    on: context.application.db
                )
                if terminalized {
                    ineligibleCount += 1
                }
                continue
            }

            candidates.append(candidate)
            deliveriesByInstallation[candidate.id] = delivery
        }

        guard !candidates.isEmpty else {
            return .init(
                candidateResolutionReached: true,
                candidateCount: deliveries.count,
                staleMissedCount: 0,
                claimedCount: 0,
                sentCount: 0,
                failedCount: ineligibleCount,
                retryableFailureCount: 0,
                noOpReason: ineligibleCount == 0 ? .allCandidatesPreviouslyClaimed : nil
            )
        }

        let dispatched = try await dispatchNotifications(
            to: candidates,
            with: payload,
            and: series,
            retryingDeliveriesByInstallation: deliveriesByInstallation,
            retryOwnerID: retryOwnerID,
            using: context
        )

        return .init(
            candidateResolutionReached: true,
            candidateCount: deliveries.count,
            staleMissedCount: dispatched.staleMissedCount,
            claimedCount: dispatched.claimedCount,
            sentCount: dispatched.sentCount,
            failedCount: dispatched.failedCount + ineligibleCount,
            retryableFailureCount: dispatched.retryableFailureCount,
            noOpReason: ineligibleCount == 0 ? dispatched.noOpReason : nil
        )
    }

    func dispatchNotifications(
        to candidates: [NotificationCandidate],
        with payload: NotificationSendJobPayload,
        and series: ArcusSeriesModel,
        retryingDeliveriesByInstallation: [UUID: NotificationRetryDelivery] = [:],
        retryOwnerID: String? = nil,
        using context: QueueContext
    ) async throws -> DispatchNotificationsResult {
        let retryOwnerID = retryOwnerID ?? self.retryOwnerID(context: context, payload: payload)
        guard candidates.count > 0 else {
            let preview = engine.buildPreviewNotification(for: series, with: payload)
            await saveNotificationDebugSnapshot(
                seriesID: payload.seriesId,
                installationID: nil,
                notificationLedgerID: nil,
                revisionUrn: payload.revisionUrn,
                mode: payload.mode,
                reason: payload.reason,
                recordKind: .previewNoCandidates,
                alert: preview,
                using: context
            )

            context.logger.info(
                "No matching candidates. No notification sent",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "mode": .string("\(String.init(reflecting: payload.mode))"),
                    "reason": .string("\(String.init(reflecting: payload.reason))")
                ]
            )
            return .init(
                candidateResolutionReached: true,
                candidateCount: 0,
                staleMissedCount: 0,
                claimedCount: 0,
                sentCount: 0,
                failedCount: 0,
                retryableFailureCount: 0,
                noOpReason: .zeroCandidates
            )
        }

        var staleMissedCount = 0
        var claimedCount = 0
        var sentCount = 0
        var failedCount = 0
        var retryableFailureCount = 0

        let evaluatedAt = Date()
        for candidate in candidates {
            let retryingDelivery = retryingDeliveriesByInstallation[candidate.id]
            let disposition = deliveryDisposition(
                for: candidate,
                evaluatedAt: evaluatedAt
            )

            let freshnessDecision: LocationFreshnessDecision
            switch disposition {
            case let .skipStale(staleDecision):
                if let retryingDelivery {
                    let terminalized = try await deliveryStore.completeRetryingFailure(
                        retryingDelivery,
                        seriesID: payload.seriesId,
                        revisionUrn: payload.revisionUrn,
                        retryOwnerID: retryOwnerID,
                        apnsErrorCode: "RetryIneligibleStaleLocation",
                        on: context.application.db
                    )
                    if terminalized {
                        failedCount += 1
                    }
                    continue
                }

                let insertResult = try await missedDecisionStore.insertStaleMissDecision(
                    .init(
                        installationID: candidate.id,
                        seriesID: payload.seriesId,
                        revisionUrn: payload.revisionUrn,
                        mode: payload.mode,
                        reason: payload.reason,
                        freshnessState: staleDecision.state,
                        missReason: .staleLocation,
                        permissionMode: candidate.locationAuth,
                        capturedAt: candidate.capturedAt,
                        receivedAt: candidate.receivedAt,
                        evaluatedAt: evaluatedAt
                    ),
                    on: context.application.db
                )
                staleMissedCount += 1
                context.logger.info(
                    "Notification candidate skipped due to stale location",
                    metadata: [
                        "installation_id": .string(candidate.id.uuidString),
                        "series_id": .string(payload.seriesId.uuidString),
                        "revision_urn": .string(payload.revisionUrn),
                        "event_type": .string(series.event),
                        "mode": .string(payload.mode.rawValue),
                        "reason": .string(payload.reason.rawValue),
                        "freshness_state": .string(staleDecision.state.rawValue),
                        "permission_mode": .string(candidate.locationAuth.rawValue),
                        "decision_outcome": .string("missed_stale_location"),
                        "miss_reason": .string(NotificationMissReason.staleLocation.rawValue),
                        "decision_persisted": .string(insertResult.inserted ? "inserted" : "already_recorded")
                    ]
                )
                continue
            case let .deliver(deliveryDecision):
                freshnessDecision = deliveryDecision
            }

            let claim: LedgerClaimResult
            if let retryingDelivery {
                claim = try await deliveryStore.reclaimRetrying(
                    retryingDelivery,
                    seriesID: payload.seriesId,
                    revisionUrn: payload.revisionUrn,
                    retryOwnerID: retryOwnerID,
                    freshnessState: freshnessDecision.state,
                    on: context.application.db
                )
            } else {
                claim = try await deliveryStore.claim(
                    installationID: candidate.id,
                    seriesID: payload.seriesId,
                    revisionUrn: payload.revisionUrn,
                    mode: payload.mode,
                    reason: payload.reason,
                    freshnessState: freshnessDecision.state,
                    retryOwnerID: retryOwnerID,
                    on: context.application.db
                )
            }
            
            guard claim.inserted else {
                continue
            }

            claimedCount += 1
            
            let alert = engine.buildNotification(
                for: series,
                with: payload,
                on: candidate,
                freshnessState: freshnessDecision.state
            )
            await saveNotificationDebugSnapshot(
                seriesID: payload.seriesId,
                installationID: candidate.id,
                notificationLedgerID: claim.id,
                revisionUrn: payload.revisionUrn,
                mode: payload.mode,
                reason: payload.reason,
                recordKind: .candidate,
                alert: alert,
                using: context
            )

            let apnsEnvironment = APNsEnvironment(rawValue: candidate.apnsEnvironment) ?? .prod
            do {
                // Use per-installation APNs environment so sandbox/prod tokens route correctly.
                try await sender.sendNotification(
                    app: context.application,
                    with: alert,
                    hotAlertPayload: .init(
                        arcusAlertId: payload.seriesId.uuidString,
                        revisionSent: series.currentRevisionSent
                    ),
                    to: candidate.apnsToken,
                    environment: apnsEnvironment
                )
            } catch {
                context.logger.error(
                    "APNs send failed",
                    metadata: [
                        "installationId": .string(candidate.id.uuidString),
                        "seriesId": .string(payload.seriesId.uuidString),
                        "revisionUrn": .string(payload.revisionUrn),
                        "error": .string(String(describing: error))
                    ]
                )

                switch failureClassifier.classify(error) {
                case .retryable(let code):
                    try await deliveryStore.markRetrying(
                        claimID: claim.id,
                        retryOwnerID: retryOwnerID,
                        retryGeneration: claim.retryGeneration,
                        apnsErrorCode: code,
                        on: context.application.db
                    )
                    retryableFailureCount += 1
                case .terminal(let code):
                    try await deliveryStore.completeFailed(
                        claimID: claim.id,
                        apnsErrorCode: code,
                        on: context.application.db
                    )
                    failedCount += 1
                case .invalidToken(let code):
                    try await deliveryStore.completeInvalidTokenFailure(
                        claimID: claim.id,
                        installationID: candidate.id,
                        failedToken: candidate.apnsToken,
                        apnsErrorCode: code,
                        on: context.application.db
                    )
                    failedCount += 1
                }
                continue
            }

            try await deliveryStore.completeSent(
                claimID: claim.id,
                on: context.application.db
            )
            sentCount += 1

            context.logger.info(
                "Notification sent to device",
                metadata: [
                    "installationId": .string(candidate.id.uuidString),
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn)
                ]
            )
        }

        let noOpReason: NotificationSendNoOpReason?
        if sentCount == 0 && failedCount == 0 && retryableFailureCount == 0 {
            if staleMissedCount > 0 && claimedCount == 0 {
                noOpReason = .allCandidatesStaleLocation
            } else {
                noOpReason = .allCandidatesPreviouslyClaimed
            }
        } else {
            noOpReason = nil
        }

        return .init(
            candidateResolutionReached: true,
            candidateCount: candidates.count,
            staleMissedCount: staleMissedCount,
            claimedCount: claimedCount,
            sentCount: sentCount,
            failedCount: failedCount,
            retryableFailureCount: retryableFailureCount,
            noOpReason: noOpReason
        )
    }

    func finishAttempt(
        context: QueueContext,
        payload: NotificationSendJobPayload,
        attemptedAt: Date,
        summary: DispatchNotificationsResult
    ) async throws {
        await recordAttempt(
            context: context,
            payload: payload,
            attemptedAt: attemptedAt,
            summary: summary
        )

        if summary.retryableFailureCount > 0 {
            throw NotificationDeliveryRetryableError.retryableFailures(
                summary.retryableFailureCount
            )
        }
    }

    func saveNotificationDebugSnapshot(
        seriesID: UUID,
        installationID: UUID?,
        notificationLedgerID: UUID?,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        recordKind: NotificationDebugRecordKind,
        alert: AlertDetails,
        using context: QueueContext
    ) async {
        let snapshot = NotificationDebugModel(
            seriesID: seriesID,
            installationID: installationID,
            notificationLedgerID: notificationLedgerID,
            revisionUrn: revisionUrn,
            mode: mode.rawValue,
            reason: reason.rawValue,
            recordKind: recordKind,
            title: alert.title,
            subtitle: alert.subTitle,
            body: alert.body
        )

        do {
            try await snapshot.create(on: context.application.db)
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                context.logger.debug(
                    "Notification debug snapshot already recorded.",
                    metadata: [
                        "seriesId": .string(seriesID.uuidString),
                        "revisionUrn": .string(revisionUrn),
                        "mode": .string(mode.rawValue),
                        "recordKind": .string(recordKind.rawValue)
                    ]
                )
                return
            }

            context.logger.error(
                "Failed to save notification debug snapshot.",
                metadata: [
                    "seriesId": .string(seriesID.uuidString),
                    "revisionUrn": .string(revisionUrn),
                    "mode": .string(mode.rawValue),
                    "recordKind": .string(recordKind.rawValue),
                    "error": .string(String(reflecting: error))
                ]
            )
        }
    }

    func recordAttempt(
        context: QueueContext,
        payload: NotificationSendJobPayload,
        attemptedAt: Date,
        summary: DispatchNotificationsResult
    ) async {
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
            seriesID: payload.seriesId,
            revisionUrn: payload.revisionUrn,
            mode: payload.mode,
            reason: payload.reason,
            outcome: outcome,
            noOpReason: summary.noOpReason,
            candidateResolutionReached: summary.candidateResolutionReached,
            candidateCount: summary.candidateCount,
            claimedCount: summary.claimedCount,
            sentCount: summary.sentCount,
            failedCount: summary.failedCount,
            attemptedAt: attemptedAt
        )

        do {
            try await attempt.create(on: context.application.db)
        } catch {
            context.logger.warning(
                "Failed to record notification send attempt.",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "error": .string(String(reflecting: error))
                ]
            )
        }
    }
}
