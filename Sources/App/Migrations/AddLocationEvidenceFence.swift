import Fluent
import FluentSQL
import Vapor

struct AddLocationEvidenceFence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("ALTER TABLE device_installations ADD COLUMN location_evidence_not_before TIMESTAMPTZ").run()
            try await sql.raw("""
                UPDATE device_installations i
                SET location_evidence_not_before = GREATEST(now(),
                    (SELECT p.captured_at FROM device_presence p WHERE p.installation_id = i.installation_id))
                WHERE i.consent_revision IS NOT NULL
                  AND (NOT i.location_sharing_enabled OR i.location_auth NOT IN ('always', 'whenInUse'))
                """).run()
            try await sql.raw("""
                UPDATE device_presence p
                SET cell_scheme = 'ugc-only', h3_cell = NULL, h3_resolution = NULL,
                    county = NULL, zone = NULL, fire_zone = NULL, county_label = NULL, fire_zone_label = NULL
                FROM device_installations i
                WHERE p.installation_id = i.installation_id AND i.location_evidence_not_before IS NOT NULL;
                """).run()
        }
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw Abort(.internalServerError) }
            try await sql.raw("LOCK TABLE device_installations IN ACCESS EXCLUSIVE MODE").run()
            guard try await sql.raw("SELECT 1 FROM device_installations WHERE location_evidence_not_before IS NOT NULL LIMIT 1").first() == nil else {
                throw Abort(.conflict, reason: "Cannot erase an observed location-consent fence")
            }
            try await sql.raw("ALTER TABLE device_installations DROP COLUMN location_evidence_not_before").run()
        }
    }
}
