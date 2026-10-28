import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Vapor

struct NotificationCandidate: Decodable {
    let id: UUID
    let apnsToken: String
    let apnsEnvironment: String
    let locationAuthRaw: String
    let capturedAt: Date
    let receivedAt: Date
    let countyLabel: String?
    let fireZoneLabel: String?

    var locationAuth: LocationAuth {
        LocationAuth(rawValue: locationAuthRaw) ?? .unknown
    }
}

struct NotificationActiveAlertMatch: Decodable, Sendable {
    let seriesId: UUID
    let revisionUrn: String
    let mode: NotificationTargetMode
    let reason: NotificationReason
}

struct NotificationCandidateStore {
    /// Recheck promoted installations after claiming, including retry claims. This cannot recall an APNs request already started.
    func acceptedConsentAllowsDelivery(_ candidate: NotificationCandidate, meso: Bool = false, on db: any Database) async throws -> Bool {
        guard let installation = try await DeviceInstallationModel.find(candidate.id, on: db) else { return false }
        guard installation.consentRevision != nil else { return true }
        return installation.isActive && installation.isSubscribed && installation.locationSharingEnabled
            && (installation.locationAuth == .always || installation.locationAuth == .whenInUse)
            && (!meso || installation.mesoNotificationsEnabled == true)
            && !installation.apnsDeviceToken.isEmpty && installation.apnsDeviceToken == candidate.apnsToken
            && installation.apnsEnvironmentRaw == candidate.apnsEnvironment
    }

    func loadMatchingActiveAlerts(
        for installationId: UUID,
        evaluatedAt: Date,
        on db: any Database
    ) async throws -> [NotificationActiveAlertMatch] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        return try await sql.raw("""
            SELECT
                s.id AS "seriesId",
                r.revision_urn AS "revisionUrn",
                o.mode AS "mode",
                o.reason AS "reason"
            FROM device_presence p
            JOIN device_installations i ON i.installation_id = p.installation_id
            CROSS JOIN arcus_series s
            JOIN alert_revisions r
              ON r.series_id = s.id
             AND r.revision_urn = s.current_revision_urn
            JOIN notification_outbox o
              ON o.series_id = s.id
             AND o.revision_urn = r.revision_urn
            LEFT JOIN arcus_geolocation g
              ON g.series_id = s.id
            WHERE p.installation_id = \(bind: installationId)
              AND i.is_active = TRUE AND i.is_subscribed = TRUE
              AND i.location_sharing_enabled = TRUE AND i.apns_device_token <> ''
              AND s.state = \(bind: EventState.active.rawValue)
              AND (s.expires IS NULL OR s.expires > \(bind: evaluatedAt))
              AND (s.ends IS NULL OR s.ends > \(bind: evaluatedAt))
              AND o.mode IN (
                  \(bind: NotificationTargetMode.h3.rawValue),
                  \(bind: NotificationTargetMode.ugc.rawValue)
              )
              AND o.reason IN (
                  \(bind: NotificationReason.new.rawValue),
                  \(bind: NotificationReason.update.rawValue)
              )
              AND (
                    (
                        o.mode = \(bind: NotificationTargetMode.h3.rawValue)
                    AND p.cell_scheme = 'h3'
                    AND p.h3_resolution = 8
                    AND p.h3_cell IS NOT NULL
                    AND p.h3_cell = ANY(g.h3_cells)
                    )
                 OR (
                        o.mode = \(bind: NotificationTargetMode.ugc.rawValue)
                    AND (
                           p.county = ANY(s.ugc_codes)
                        OR p.zone = ANY(s.ugc_codes)
                        OR p.fire_zone = ANY(s.ugc_codes)
                    )
                 )
              )
            """)
            .all(decoding: NotificationActiveAlertMatch.self)
    }

    func loadUGCCandidates(
        ugcCodes: [String],
        capturedAtOrAfter cutoff: Date,
        installationId: UUID? = nil,
        on db: any Database
    ) async throws -> [NotificationCandidate] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        return try await sql.raw("""
            SELECT
                i.installation_id AS "id",
                i.apns_device_token AS "apnsToken",
                i.apns_environment AS "apnsEnvironment",
                i.location_auth AS "locationAuthRaw",
                p.captured_at AS "capturedAt",
                p.received_at AS "receivedAt",
                p.county_label AS "countyLabel",
                p.fire_zone_label AS "fireZoneLabel"
            FROM device_installations i
            JOIN device_presence p on i.installation_id = p.installation_id
            WHERE i.is_active = TRUE
              AND i.is_subscribed = TRUE AND i.location_sharing_enabled = TRUE
              AND i.apns_device_token <> ''
              AND (\(bind: installationId)::uuid IS NULL OR i.installation_id = \(bind: installationId)::uuid)
              AND p.captured_at >= \(bind: cutoff)
              AND (
                  p.county  = ANY(\(bind: ugcCodes)::text[])
                OR p.zone  = ANY(\(bind: ugcCodes)::text[])
                OR p.fire_zone = ANY(\(bind: ugcCodes)::text[])
              )
            """)
            .all(decoding: NotificationCandidate.self)
    }

    func loadH3Candidates(
        cells: [Int64],
        capturedAtOrAfter cutoff: Date,
        installationId: UUID? = nil,
        on db: any Database
    ) async throws -> [NotificationCandidate] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        guard cells.count > 0 else { return [] }

        return try await sql.raw("""
            SELECT
                i.installation_id AS "id",
                i.apns_device_token AS "apnsToken",
                i.apns_environment AS "apnsEnvironment",
                i.location_auth AS "locationAuthRaw",
                p.captured_at AS "capturedAt",
                p.received_at AS "receivedAt",
                p.county_label AS "countyLabel",
                p.fire_zone_label AS "fireZoneLabel"
            FROM device_installations i
            JOIN device_presence p
              ON i.installation_id = p.installation_id
            WHERE i.is_active = TRUE
              AND i.is_subscribed = TRUE AND i.location_sharing_enabled = TRUE
              AND i.apns_device_token <> ''
              AND (\(bind: installationId)::uuid IS NULL OR i.installation_id = \(bind: installationId)::uuid)
              AND p.cell_scheme = 'h3'
              AND p.h3_resolution = 8
              AND p.h3_cell IS NOT NULL
              AND p.h3_cell = ANY(\(bind: cells)::bigint[])
              AND p.captured_at >= \(bind: cutoff)
            """)
            .all(decoding: NotificationCandidate.self)
    }
}
