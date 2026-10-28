import Fluent
import FluentSQL
import Vapor

struct AddDeviceConsentRevision: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { throw Abort(.internalServerError) }
        try await sql.raw("""
            ALTER TABLE device_installations
            ADD COLUMN consent_revision BIGINT CHECK (consent_revision > 0),
            ADD COLUMN location_sharing_enabled BOOLEAN NOT NULL DEFAULT TRUE
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Never erase a promoted installation's permanent downgrade fence.
            try await sql.raw("LOCK TABLE device_installations IN ACCESS EXCLUSIVE MODE").run()
            guard try await sql.raw("SELECT 1 FROM device_installations WHERE consent_revision IS NOT NULL LIMIT 1").first() == nil else {
                throw Abort(.conflict, reason: "Cannot revert consent revision while v3 installations exist")
            }
            try await sql.raw("ALTER TABLE device_installations DROP COLUMN consent_revision, DROP COLUMN location_sharing_enabled").run()
        }
    }
}
