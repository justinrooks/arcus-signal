import Fluent
import SQLKit

struct CreateSPCMesos: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("spc_mesos")
            .id()
            .field("product_key", .string, .required)
            .field("issue_year", .int, .required)
            .field("md_number", .int, .required)
            .field("issued", .datetime, .required)
            .field("valid_start", .datetime, .required)
            .field("valid_end", .datetime, .required)
            .field("title", .string, .required)
            .field("source_url", .string, .required)
            .field("areas_affected", .string, .required)
            .field("summary", .string, .required)
            .field("concerning", .string)
            .field("watch_probability", .double)
            .field("watch_probability_text", .string, .required)
            .field("peak_wind_mph", .int)
            .field("hail_range_inches", .double)
            .field("tornado_strength", .string)
            .field("content_fingerprint", .string, .required)
            .field("first_seen", .datetime, .required)
            .field("last_seen", .datetime, .required)
            .unique(on: "product_key")
            .unique(on: "issue_year", "md_number")
            .create()

        try await db.schema("spc_meso_geolocation")
            .id()
            .field("meso_id", .uuid, .required,
                   .references("spc_mesos", "id", onDelete: .cascade))
            .field("geometry", .dictionary, .required)
            .field("geometry_hash", .string, .required)
            .field("h3_cells", .array(of: .int64), .required)
            .field("h3_resolution", .int16)
            .field("h3_hash", .string)
            .unique(on: "meso_id")
            .create()

        guard let sql = db as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE spc_meso_geolocation
                ALTER COLUMN h3_cells SET DEFAULT '{}'::bigint[];
            """).run()
        try await sql.raw("""
            CREATE INDEX gin_spc_meso_geolocation_h3_cells
                ON spc_meso_geolocation USING GIN (h3_cells);
            """).run()
        try await sql.raw("""
            CREATE INDEX idx_spc_mesos_valid_end ON spc_mesos (valid_end);
            """).run()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("spc_meso_geolocation").delete()
        try await db.schema("spc_mesos").delete()
    }
}
