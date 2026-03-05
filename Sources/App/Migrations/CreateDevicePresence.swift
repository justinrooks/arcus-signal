import Fluent
import SQLKit

struct CreateDevicePresence: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DevicePresenceModel.schema)
            .field(
                "installation_id",
                .string,
                .identifier(auto: false),
                .references(DeviceInstallationModel.schema, "installation_id", onDelete: .cascade)
            )
            .field("captured_at", .datetime, .required)
            .field("received_at", .datetime, .required)
            .field("location_age_seconds", .double, .required)
            .field("horizontal_accuracy_meters", .double, .required)
            .field("cell_scheme", .string, .required)
            .field("h3_cell", .int64)
            .field("h3_resolution", .int)
            .field("county", .string)
            .field("zone", .string)
            .field("fire_zone", .string)
            .field("source", .string, .required)
            .field("created_at", .datetime, .required)
            .field("updated_at", .datetime, .required)
            .create()

        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE device_presence
              ALTER COLUMN received_at SET DEFAULT now(),
              ALTER COLUMN cell_scheme SET DEFAULT 'ugc-only',
              ALTER COLUMN source SET DEFAULT 'unknown',
              ALTER COLUMN created_at SET DEFAULT now(),
              ALTER COLUMN updated_at SET DEFAULT now();
        """).run()

        try await sql.raw("""
            ALTER TABLE device_presence
              ADD CONSTRAINT device_presence_cell_scheme_check
              CHECK (cell_scheme IN ('h3', 'ugc-only')),
              ADD CONSTRAINT device_presence_source_check
              CHECK (source IN ('foreground', 'backgroundRefresh', 'significantChange', 'manual', 'unknown')),
              ADD CONSTRAINT device_presence_h3_resolution_range_check
              CHECK (h3_resolution IS NULL OR (h3_resolution >= 0 AND h3_resolution <= 15)),
              ADD CONSTRAINT device_presence_location_age_non_negative_check
              CHECK (location_age_seconds >= 0),
              ADD CONSTRAINT device_presence_accuracy_non_negative_check
              CHECK (horizontal_accuracy_meters >= 0),
              ADD CONSTRAINT device_presence_cell_scheme_h3_fields_check
              CHECK (
                cell_scheme <> 'h3'
                OR (h3_cell IS NOT NULL AND h3_resolution IS NOT NULL)
              );
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_presence_captured_at
            ON device_presence (captured_at);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_presence_h3_cell
            ON device_presence (h3_cell);
        """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_device_presence_zone_triplet
            ON device_presence (county, zone, fire_zone);
        """).run()
    }

    func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_device_presence_captured_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_device_presence_h3_cell;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_device_presence_zone_triplet;").run()
        }
        try await database.schema(DevicePresenceModel.schema).delete()
    }
}

