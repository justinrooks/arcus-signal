import Fluent
import SQLKit

struct ConvertInstallationIDsToUUID: AsyncMigration {
    func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_presence
              DROP CONSTRAINT IF EXISTS device_presence_installation_id_fkey;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      DROP CONSTRAINT IF EXISTS notification_ledger_installation_id_fkey;
                END IF;
            END
            $$;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_installations
              ALTER COLUMN installation_id TYPE uuid
              USING installation_id::uuid;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
              ALTER COLUMN installation_id TYPE uuid
              USING installation_id::uuid;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      ALTER COLUMN installation_id TYPE uuid
                      USING installation_id::uuid;
                END IF;
            END
            $$;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
              ADD CONSTRAINT device_presence_installation_id_fkey
              FOREIGN KEY (installation_id)
              REFERENCES device_installations(installation_id)
              ON DELETE CASCADE;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      ADD CONSTRAINT notification_ledger_installation_id_fkey
                      FOREIGN KEY (installation_id)
                      REFERENCES device_installations(installation_id)
                      ON DELETE CASCADE;
                END IF;
            END
            $$;
        """).run()
    }

    func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_presence
              DROP CONSTRAINT IF EXISTS device_presence_installation_id_fkey;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      DROP CONSTRAINT IF EXISTS notification_ledger_installation_id_fkey;
                END IF;
            END
            $$;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      ALTER COLUMN installation_id TYPE text
                      USING installation_id::text;
                END IF;
            END
            $$;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
              ALTER COLUMN installation_id TYPE text
              USING installation_id::text;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_installations
              ALTER COLUMN installation_id TYPE text
              USING installation_id::text;
        """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
              ADD CONSTRAINT device_presence_installation_id_fkey
              FOREIGN KEY (installation_id)
              REFERENCES device_installations(installation_id)
              ON DELETE CASCADE;
        """).run()

        try await sql.raw("""
            DO $$
            BEGIN
                IF to_regclass('public.notification_ledger') IS NOT NULL THEN
                    ALTER TABLE notification_ledger
                      ADD CONSTRAINT notification_ledger_installation_id_fkey
                      FOREIGN KEY (installation_id)
                      REFERENCES device_installations(installation_id)
                      ON DELETE CASCADE;
                END IF;
            END
            $$;
        """).run()
    }
}
