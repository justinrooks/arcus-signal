import Fluent
import SQLKit

struct UpdateDevicePresenceSourceConstraintForExpandedLocationUploadSources: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_presence
            DROP CONSTRAINT IF EXISTS device_presence_source_check;
            """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
            ADD CONSTRAINT device_presence_source_check
            CHECK (
                source IN (
                    'foreground',
                    'backgroundRefresh',
                    'significantChange',
                    'manual',
                    'foregroundPrime',
                    'foregroundActivate',
                    'foregroundLocationChange',
                    'manualRefresh',
                    'backgroundLocationChange',
                    'onboarding',
                    'settingsPreference',
                    'unknown'
                )
            );
            """).run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_presence
            DROP CONSTRAINT IF EXISTS device_presence_source_check;
            """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
            ADD CONSTRAINT device_presence_source_check
            CHECK (
                source IN (
                    'foreground',
                    'backgroundRefresh',
                    'significantChange',
                    'manual',
                    'foregroundPrime',
                    'foregroundActivate',
                    'foregroundLocationChange',
                    'manualRefresh',
                    'backgroundLocationChange',
                    'onboarding',
                    'settingsPreference',
                    'unknown'
                )
            );
            """).run()
    }
}
