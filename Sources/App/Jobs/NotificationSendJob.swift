//
//  NotificationSendJob.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/3/26.
//

import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

struct NotificationCandidate: Decodable {
    let id: UUID
    let apnsToken: String
}

struct LedgerClaimResult {
    let inserted: Bool
    let id: UUID?
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
        
        // Grab the associated series
        let series = try await ArcusSeriesModel.query(on: context.application.db)
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
            return
        }
        
        let candidates = try await loadUGCCandidates(
            ugcCodes: series.ugcCodes,
            freshnessCutoff: nil,
            on: context.application.db
        )
        
        guard candidates.count > 0 else {
            context.logger.info(
                "No matching candidates. No notification sent",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "mode": .string("\(String.init(reflecting: payload.mode))"),
                    "reason": .string("\(String.init(reflecting: payload.reason))")
                ]
            )
            return
        }
    
        // Build an alert
        let alertKind = EventKind.toNwsEventName(series.event)
        
        let alert: AlertDetails = .init(
            title: "Weather Alert for your area",
            subTitle: "\(alertKind.sentenceCased) issued",
            body: series.title ?? "Unknown series"
        )
        
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
            
            // Build your notification payload here.
            
            do {
                // Replace this with your actual APNs send call.
                context.logger.info(
                    "Sending APNs",
                    metadata: [
                        "installationId": .string(candidate.id.uuidString),
                        "seriesId": .string(payload.seriesId.uuidString),
                        "revisionUrn": .string(payload.revisionUrn)
                    ]
                )
                
                try await sender.sendNotification(app: context.application, with: alert, to: candidate.apnsToken)
                
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
                
                // v1: log and move on
                // later: update ledger status / classify retryable vs permanent
            }
        }

        context.logger.info(
            "Notifications sent",
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
                    id,
                    apns_token AS "apnsToken"
                FROM device_installations
                WHERE notifications_enabled = TRUE
                  AND apns_token IS NOT NULL
                  AND ugc_codes && \(bind: ugcCodes)::text[]
                  AND last_location_at IS NOT NULL
                  AND last_location_at >= \(bind: freshnessCutoff)
                """)
                .all(decoding: NotificationCandidate.self)
        } else {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken"
                FROM device_installations i
                JOIN device_presence p on i.installation_id = p.installation_id
                WHERE (
                      p.county  = ANY(\(bind: ugcCodes)::text[])
                    OR p.zone  = ANY(\(bind: ugcCodes)::text[])
                    OR p.fire_zone = ANY(\(bind: ugcCodes)::text[])
                )
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
                (id, installation_id, series_id, revision_urn, mode, reason, created)
            VALUES
                (\(bind: newID),
                 \(bind: installationID),
                 \(bind: seriesID),
                 \(bind: revisionUrn),
                 \(bind: mode),
                 \(bind: reason),
                 NOW())
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
}
