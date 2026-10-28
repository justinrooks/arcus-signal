import Fluent

struct CreateInstallationCredentials: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // No device-installation FK: non-notification users can enroll before registering delivery.
        try await database.schema(InstallationCredentialStore.schema)
            .field("installation_id", .uuid, .identifier(auto: false))
            .field("verifier", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(InstallationCredentialStore.schema).delete()
    }
}
