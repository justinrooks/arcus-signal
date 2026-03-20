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
    let countyLabel: String?
    let fireZoneLabel: String?
//    let matchReason: String
//    let locality: String?
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
                return
            }
            
            // Get our list of candidates
            let h3Candidates = try await loadH3Candidates(
                cells: geo.h3Cells,
                freshnessCutoff: nil,
                on: context.application.db
            )
            
            try await dispatchNotifications(
                to: h3Candidates,
                with: payload,
                and: series,
                using: context
            )
        } else {
            // we only have 2 modes right now, so its ugc
            let ugcCandidates = try await loadUGCCandidates(
                ugcCodes: series.ugcCodes,
                freshnessCutoff: nil,
                on: context.application.db
            )

            try await dispatchNotifications(
                to: ugcCandidates,
                with: payload,
                and: series,
                using: context
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
    ) async throws {
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
            let alert = engine.buildNotification(for: series, with: payload, on: candidate)
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
                    try await existingClaim.save(on: context.application.db)
                }
                
                context.logger.info(
                    "Notification sent to device",
                    metadata: [
                        "installationId": .string(candidate.id.uuidString),
                        "seriesId": .string(payload.seriesId.uuidString),
                        "revisionUrn": .string(payload.revisionUrn)
                    ]
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
                guard let existingClaim = try await NotificationLedgerModel.find(claim.id, on: context.application.db) else {
                    throw Abort(.notFound)
                }
                // TODO: figure out retries
                // At least we aren't dropping them now
                existingClaim.status = "failed"
                try await existingClaim.save(on: context.application.db)
            }
        }
    }
}
