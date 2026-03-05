import Fluent
import SQLKit

struct CreateDeviceInstallations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DeviceInstallationModel.schema)
            .field("installation_id", .string, .identifier(auto: false))
            .field("apns_device_token", .string, .required)
            .field("apns_environment", .string, .required)
            .field("platform", .string, .required)
            .field("os_version", .string, .required)
            .field("app_version", .string, .required)
            .field("build_number", .string, .required)
            .field("location_auth", .string, .required)
            .field("is_active", .bool, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .field("last_seen_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_installations
              ALTER COLUMN is_active SET DEFAULT true,
              ALTER COLUMN created_at SET DEFAULT now(),
              ALTER COLUMN updated_at SET DEFAULT now(),
              ALTER COLUMN last_seen_at SET DEFAULT now();
        """).run()

        try await sql.raw("""
            ALTER TABLE device_installations
              ADD CONSTRAINT device_installations_apns_environment_check
              CHECK (apns_environment IN ('prod', 'sandbox')),
              ADD CONSTRAINT device_installations_platform_check
              CHECK (platform IN ('iOS', 'watchOS')),
              ADD CONSTRAINT device_installations_location_auth_check
              CHECK (location_auth IN ('always', 'whenInUse', 'denied', 'restricted', 'notDetermined', 'unknown'));
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_installations_apns_device_token
            ON device_installations (apns_device_token);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_installations_is_active_last_seen_at
            ON device_installations (is_active, last_seen_at);
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_device_installations_apns_device_token;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_device_installations_is_active_last_seen_at;").run()
        }
        try await database.schema(DeviceInstallationModel.schema).delete()
    }
}

