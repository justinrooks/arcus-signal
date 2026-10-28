import Fluent
import FluentSQL
import Foundation
import Vapor

func configureMesoNotifications(on app: Application, value: String?) {
    app.mesoNotificationsEnabled = value == "true"
}

extension Application {
    private struct MesoNotificationsKey: StorageKey { typealias Value = Bool }

    var mesoNotificationsEnabled: Bool {
        get { storage[MesoNotificationsKey.self] ?? false }
        set { storage[MesoNotificationsKey.self] = newValue }
    }
}

extension NotificationCandidateStore {
    /// Meso eligibility deliberately has no UGC fallback or implicit capability.
    func loadMesoCandidates(productID: String, installationID: UUID? = nil, evaluatedAt: Date, on db: any Database) async throws -> [NotificationCandidate] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        return try await sql.raw("""
            SELECT i.installation_id AS "id", i.apns_device_token AS "apnsToken",
                   i.apns_environment AS "apnsEnvironment", i.location_auth AS "locationAuthRaw",
                   p.captured_at AS "capturedAt", p.received_at AS "receivedAt",
                   p.county_label AS "countyLabel", p.fire_zone_label AS "fireZoneLabel"
            \(mesoMatchingRows(productID: productID, installationID: installationID, evaluatedAt: evaluatedAt))
            """).all(decoding: NotificationCandidate.self)
    }

    func loadMatchingActiveMesos(for installationID: UUID, evaluatedAt: Date, on db: any Database) async throws -> [MesoPresenceMatch] {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        return try await sql.raw("""
            SELECT s.issue_year AS "issueYear", s.md_number AS "number"
            \(mesoMatchingRows(productID: nil, installationID: installationID, evaluatedAt: evaluatedAt))
            ORDER BY s.product_key
            """).all(decoding: MesoPresenceMatch.self)
    }

    private func mesoMatchingRows(productID: String?, installationID: UUID?, evaluatedAt: Date) -> SQLQueryString {
        var query: SQLQueryString = """
            FROM spc_mesos s
            JOIN spc_meso_geolocation g ON g.meso_id = s.id
            JOIN device_presence p ON p.h3_cell = ANY(g.h3_cells)
            JOIN device_installations i ON i.installation_id = p.installation_id
            WHERE s.valid_start <= \(bind: evaluatedAt) AND s.valid_end > \(bind: evaluatedAt)
              AND g.h3_resolution = 8 AND g.h3_hash IS NOT NULL
              AND p.cell_scheme = 'h3' AND p.h3_resolution = 8
              AND i.is_active = TRUE AND i.is_subscribed = TRUE AND i.location_sharing_enabled = TRUE
              AND i.meso_notifications_enabled = TRUE AND i.apns_device_token <> ''
              AND p.captured_at >= \(bind: evaluatedAt.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold))
            """
        if let productID { query += " AND s.product_key = \(bind: productID)" }
        if let installationID { query += " AND i.installation_id = \(bind: installationID)" }
        return query
    }
}

struct MesoPresenceMatch: Decodable, Sendable {
    let issueYear: Int
    let number: Int
}
