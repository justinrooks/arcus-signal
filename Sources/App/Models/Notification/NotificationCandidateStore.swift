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

struct NotificationCandidateStore {
    func loadUGCCandidates(
        ugcCodes: [String],
        capturedAtOrAfter cutoff: Date,
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
              AND i.is_subscribed = TRUE
              AND i.apns_device_token <> ''
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
              AND i.is_subscribed = TRUE
              AND i.apns_device_token <> ''
              AND p.h3_cell IS NOT NULL
              AND p.h3_cell = ANY(\(bind: cells)::bigint[])
              AND p.captured_at >= \(bind: cutoff)
            """)
            .all(decoding: NotificationCandidate.self)
    }
}
