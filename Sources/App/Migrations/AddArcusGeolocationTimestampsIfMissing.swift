import Fluent
import SQLKit

struct AddArcusGeolocationTimestampsIfMissing: AsyncMigration {
    func prepare(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE arcus_geolocation
              ADD COLUMN IF NOT EXISTS created TIMESTAMPTZ,
              ADD COLUMN IF NOT EXISTS updated TIMESTAMPTZ;
        """).run()

        try await sql.raw("""
            UPDATE arcus_geolocation
            SET created = COALESCE(created, now()),
                updated = COALESCE(updated, now());
        """).run()

        try await sql.raw("""
            ALTER TABLE arcus_geolocation
              ALTER COLUMN created SET DEFAULT now(),
              ALTER COLUMN updated SET DEFAULT now(),
              ALTER COLUMN created SET NOT NULL,
              ALTER COLUMN updated SET NOT NULL;
        """).run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE arcus_geolocation
              DROP COLUMN IF EXISTS created,
              DROP COLUMN IF EXISTS updated;
        """).run()
    }
}
