import Fluent
import SQLKit

struct AddMesoNotificationPreferenceToDeviceInstallation: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            try await database.schema(DeviceInstallationModel.schema)
                .field("meso_notifications_enabled", .bool)
                .update()
            return
        }

        try await sql.raw("""
            ALTER TABLE device_installations
            ADD COLUMN IF NOT EXISTS meso_notifications_enabled BOOLEAN;
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(DeviceInstallationModel.schema)
            .deleteField("meso_notifications_enabled")
            .update()
    }
}
