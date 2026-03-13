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
    let apnsEnvironment: String
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
            .with(\.$geolocation)
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
        
        let ugcCandidates = try await loadUGCCandidates(
            ugcCodes: series.ugcCodes,
            freshnessCutoff: nil,
            on: context.application.db
        )
        
        let h3Candidates = try await loadH3Candidates(
            cells: series.geolocation?.h3Cells ?? [],
            freshnessCutoff: nil,
            on: context.application.db
        )
        
        let candidates = ugcCandidates + h3Candidates
        
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
        
        let title:String = switch payload.reason {
        case .new: series.headline ?? "New weather alert for your area"
        case .update: "Updated weather alert for your area"
        case .cancelInError: "Weather alert for your area has been cancelled"
        case .endedAllClear: "Weather alert as ended for your area"
        }
        
        let alert: AlertDetails = .init(
            title: title,
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
                
                // Use per-installation APNs environment so sandbox/prod tokens route correctly.
                let apnsEnvironment = APNsEnvironment(rawValue: candidate.apnsEnvironment) ?? .prod
                try await sender.sendNotification(
                    app: context.application,
                    with: alert,
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
                    installation_id AS "id",
                    apns_device_token AS "apnsToken",
                    apns_environment AS "apnsEnvironment"
                FROM device_installations
                WHERE is_active = TRUE
                  AND apns_device_token <> ''
                  AND last_seen_at >= \(bind: freshnessCutoff)
                """)
                .all(decoding: NotificationCandidate.self)
        } else {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment"
                FROM device_installations i
                JOIN device_presence p on i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
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
                    i.apns_environment AS "apnsEnvironment"
                FROM device_installations i
                JOIN device_presence p
                  ON i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.apns_device_token <> ''
                  AND p.h3_cell IS NOT NULL
                  AND 'p.h3_cell = ANY(\(bind: cells)::bigint[])
                  AND last_seen_at >= \(bind: freshnessCutoff)
                """)
                .all(decoding: NotificationCandidate.self)
        } else {
            return try await sql.raw("""
                SELECT
                    i.installation_id AS "id",
                    i.apns_device_token AS "apnsToken",
                    i.apns_environment AS "apnsEnvironment"
                FROM device_installations i
                JOIN device_presence p
                  ON i.installation_id = p.installation_id
                WHERE i.is_active = TRUE
                  AND i.apns_device_token <> ''
                  AND p.h3_cell IS NOT NULL
                  AND 'p.h3_cell = ANY(\(bind: cells)::bigint[])
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
