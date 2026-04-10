//
//  NotificationSendJob.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/3/26.
//

import APNSCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

struct NotificationCandidate: Decodable {
    let id: UUID
    let apnsToken: String
    let apnsEnvironment: String
    let countyLabel: String?
    let fireZoneLabel: String?
//    let matchReason: String
//    let locality: String?
}

struct LedgerClaimResult {
    let inserted: Bool
    let id: UUID?
}

struct DispatchNotificationsResult {
    let candidateResolutionReached: Bool
    let candidateCount: Int
    let claimedCount: Int
    let sentCount: Int
    let failedCount: Int
    let noOpReason: NotificationSendNoOpReason?
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
    
    init(
        seriesId: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason
    ) {
        self.seriesId = seriesId
        self.revisionUrn = revisionUrn
        self.mode = mode
        self.reason = reason
    }
}

public struct NotificationSendJob: AsyncJob {
    public typealias Payload = NotificationSendJobPayload
    private let sender: APNsClient = APNsClient()
    private let engine: NotificationEngine = NotificationEngine()
    
    public init () {}
    
    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
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
//                    .filter(\.$ends < .now)
            }
            .first()
        
        guard let series, series.currentRevisionUrn == payload.revisionUrn else {
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
            await recordAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: .init(
                    candidateResolutionReached: false,
                    candidateCount: 0,
                    claimedCount: 0,
                    sentCount: 0,
                    failedCount: 0,
                    noOpReason: .staleRevisionMismatch
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
                await recordAttempt(
                    context: context,
                    payload: payload,
                    attemptedAt: attemptedAt,
                    summary: .init(
                        candidateResolutionReached: false,
                        candidateCount: 0,
                        claimedCount: 0,
                        sentCount: 0,
                        failedCount: 0,
                        noOpReason: .missingGeolocation
                    )
                )
                return
            }
            
            // Get our list of candidates
            let h3Candidates = try await loadH3Candidates(
                cells: geo.h3Cells,
                freshnessCutoff: nil,
                on: context.application.db
            )
            
            let summary = try await dispatchNotifications(
                to: h3Candidates,
                with: payload,
                and: series,
                using: context
            )
            await recordAttempt(
                context: context,
                payload: payload,
                attemptedAt: attemptedAt,
                summary: summary
            )
        } else {
            // we only have 2 modes right now, so its ugc
            let ugcCandidates = try await loadUGCCandidates(
                ugcCodes: series.ugcCodes,
                freshnessCutoff: nil,
                on: context.application.db
            )

            let summary = try await dispatchNotifications(
                to: ugcCandidates,
                with: payload,
                and: series,
                using: context
            )
            await recordAttempt(
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
        context.logger.error(
            "NotificationSendJob failed.",
            metadata: ["error": .string(String(describing: error))]
        )
        // TODO: handle this and throw it back in the pile for reprocessing
    }
}


private extension NotificationSendJob {
    func loadUGCCandidates(
        ugcCodes: [String],
        freshnessCutoff: Date?,
        on db: any Database
    ) async throws -> [NotificationCandidate] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        if let freshnessCutoff {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment",
                    p.county_label as countyLabel,
                    p.fire_zone_label as fireZoneLabel
                FROM device_installations i
                JOIN device_presence p on i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.is_subscribed = TRUE
                  AND i.apns_device_token <> ''
                  AND i.last_seen_at >= \(bind: freshnessCutoff)
                  AND (
                      p.county  = ANY(\(bind: ugcCodes)::text[])
                    OR p.zone  = ANY(\(bind: ugcCodes)::text[])
                    OR p.fire_zone = ANY(\(bind: ugcCodes)::text[])
                  )
                """)
                .all(decoding: NotificationCandidate.self)
        } else {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment",
                    p.county_label as countyLabel,
                    p.fire_zone_label as fireZoneLabel
                FROM device_installations i
                JOIN device_presence p on i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.is_subscribed = TRUE
                  AND i.apns_device_token <> ''
                  AND (
                      p.county  = ANY(\(bind: ugcCodes)::text[])
                    OR p.zone  = ANY(\(bind: ugcCodes)::text[])
                    OR p.fire_zone = ANY(\(bind: ugcCodes)::text[])
                  )
                """)
                .all(decoding: NotificationCandidate.self)
        }
    }
    
    func loadH3Candidates(
        cells: [Int64],
        freshnessCutoff: Date?,
        on db: any Database
    ) async throws -> [NotificationCandidate] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        guard cells.count > 0 else { return [] }

        if let freshnessCutoff {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment",
                    p.county_label as countyLabel,
                    p.fire_zone_label as fireZoneLabel
                FROM device_installations i
                JOIN device_presence p
                  ON i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.is_subscribed = TRUE
                  AND i.apns_device_token <> ''
                  AND p.h3_cell IS NOT NULL
                  AND p.h3_cell = ANY(\(bind: cells)::bigint[])
                  AND i.last_seen_at >= \(bind: freshnessCutoff)
                """)
                .all(decoding: NotificationCandidate.self)
        } else {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment",
                    p.county_label as countyLabel,
                    p.fire_zone_label as fireZoneLabel
                FROM device_installations i
                JOIN device_presence p
                  ON i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.is_subscribed = TRUE
                  AND i.apns_device_token <> ''
                  AND p.h3_cell IS NOT NULL
                  AND p.h3_cell = ANY(\(bind: cells)::bigint[])
                """)
                .all(decoding: NotificationCandidate.self)
        }
    }
    
    func claimNotificationLedger(
        installationID: UUID,
        seriesID: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        on db: any Database
    ) async throws -> LedgerClaimResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let newID = UUID()

        let row = try await sql.raw("""
            INSERT INTO notification_ledger
                (id, installation_id, series_id, revision_urn, mode, reason, created, status)
            VALUES
                (\(bind: newID),
                 \(bind: installationID),
                 \(bind: seriesID),
                 \(bind: revisionUrn),
                 \(bind: mode),
                 \(bind: reason),
                 NOW(),
                'claimed')
            ON CONFLICT (installation_id, series_id, revision_urn)
            DO NOTHING
            RETURNING id
            """)
            .first()

        if let row {
            let returnedID = try row.decode(column: "id", as: UUID.self)
            return LedgerClaimResult(inserted: true, id: returnedID)
        } else {
            return LedgerClaimResult(inserted: false, id: nil)
        }
    }
    
    func dispatchNotifications(
        to candidates: [NotificationCandidate],
        with payload: NotificationSendJobPayload,
        and series: ArcusSeriesModel,
        using context: QueueContext
    ) async throws -> DispatchNotificationsResult {
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
                claimedCount: 0,
                sentCount: 0,
                failedCount: 0,
                noOpReason: .zeroCandidates
            )
        }

        var claimedCount = 0
        var sentCount = 0
        var failedCount = 0

        for candidate in candidates {
            let claim = try await claimNotificationLedger(
                installationID: candidate.id,
                seriesID: payload.seriesId,
                revisionUrn: payload.revisionUrn,
                mode: payload.mode,
                reason: payload.reason,
                on: context.application.db
            )
            
            guard claim.inserted else {
                continue
            }

            claimedCount += 1
            
            let alert = engine.buildNotification(for: series, with: payload, on: candidate)
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

            do {
                // Use per-installation APNs environment so sandbox/prod tokens route correctly.
                let apnsEnvironment = APNsEnvironment(rawValue: candidate.apnsEnvironment) ?? .prod
                try await sender.sendNotification(
                    app: context.application,
                    with: alert,
                    to: candidate.apnsToken,
                    environment: apnsEnvironment
                )

                if let existingClaim = try await NotificationLedgerModel.find(claim.id, on: context.application.db) {
                    existingClaim.status = "sent"
                    existingClaim.completedAt = .now
                    try await existingClaim.save(on: context.application.db)
                }
                sentCount += 1
                
                context.logger.info(
                    "Notification sent to device",
                    metadata: [
                        "installationId": .string(candidate.id.uuidString),
                        "seriesId": .string(payload.seriesId.uuidString),
                        "revisionUrn": .string(payload.revisionUrn)
                    ]
                )
            } catch let error as APNSError {
                // Handle specific Apple response codes
//                switch error.reason {
//                case .badDeviceToken:
//                    context.logger.error("Token is invalid. Remove from DB.")
//                case .unregistered:
//                    context.logger.error("User deleted app. Delete token.")
//                case .tooManyRequests:
//                    context.logger.error("Rate limited. Slow down!")
//                case .expiredProviderToken:
//                    context.logger.critical("Check your .p8 file or Team ID settings.")
//                
//                default:
                context.logger.error("APNS rejected request: \(error.reason.debugDescription)")
//                }
                
                guard let existingClaim = try await NotificationLedgerModel.find(claim.id, on: context.application.db) else {
                    throw Abort(.notFound)
                }
                
                // TODO: figure out retries
                // At least we aren't dropping them now
                if let reason = error.reason {
                    existingClaim.apnsErrorCode = reason.errorDescription
                } else {
                    existingClaim.apnsErrorCode = error.reason.debugDescription
                }

                existingClaim.status = "failed"
                existingClaim.completedAt = .now
                try await existingClaim.save(on: context.application.db)
                failedCount += 1
                
//
//                200
//                Success.
//                400
//                Bad request.
//                403
//                There was an error with the certificate or with the provider’s authentication token.
//                404
//                The request contained an invalid :path value.
//                405
//                The request used an invalid :method value. Only POST requests are supported.
//                410
//                The device token is no longer active for the topic.
//                413
//                The notification payload was too large.
//                429
//                The server received too many requests for the same device token.
//                500
//                Internal server error.
//                503
//                The server is shutting down and unavailable.
                
                // You can also check by HTTP status code if preferred
                // if error.status == .gone { ... }
                
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
                guard let existingClaim = try await NotificationLedgerModel.find(claim.id, on: context.application.db) else {
                    throw Abort(.notFound)
                }
                // TODO: figure out retries
                // At least we aren't dropping them now
                existingClaim.status = "failed"
                existingClaim.completedAt = .now
                try await existingClaim.save(on: context.application.db)
                failedCount += 1
            }
        }

        let noOpReason: NotificationSendNoOpReason?
        if sentCount == 0 && failedCount == 0 {
            noOpReason = .allCandidatesPreviouslyClaimed
        } else {
            noOpReason = nil
        }

        return .init(
            candidateResolutionReached: true,
            candidateCount: candidates.count,
            claimedCount: claimedCount,
            sentCount: sentCount,
            failedCount: failedCount,
            noOpReason: noOpReason
        )
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
