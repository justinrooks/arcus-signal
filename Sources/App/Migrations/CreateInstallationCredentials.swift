import Fluent
import FluentSQL
import Vapor

struct CreateInstallationCredentials: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // No device-installation FK: non-notification users can enroll before registering delivery.
        try await database.schema(InstallationCredentialStore.schema)
            .field("installation_id", .uuid, .identifier(auto: false))
            .field("verifier", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Credential rollback requires a SQL transaction")
            }
            // Hold through DROP so enrollment cannot race an empty-table check.
            try await sql.raw("LOCK TABLE installation_credentials IN ACCESS EXCLUSIVE MODE").run()
            guard try await sql.raw("SELECT 1 FROM installation_credentials LIMIT 1").first() == nil else {
                throw Abort(.conflict, reason: "Cannot revert installation credentials while enrolled installations exist")
            }
            try await transaction.schema(InstallationCredentialStore.schema).delete()
        }
    }
}
