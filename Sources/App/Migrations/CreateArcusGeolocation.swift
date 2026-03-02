//
//  CreateArcusGeolocation.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/1/26.
//

import Fluent
import Foundation
import SQLKit

struct CreateArcusGeolocation: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(ArcusGeolocationModel.schema)
            .field("id", .uuid, .identifier(auto: false))

            .field("series_id", .uuid, .required,
                   .references(ArcusSeriesModel.schema, "id", onDelete: .cascade))

            // GeoShape? stored as JSONB in Postgres
            .field("geometry", .dictionary, .required)
            .field("geometry_hash", .string, .required)
            .field("h3_cells", .array(of: .int64), .required)
            .field("h3_resolution", .int16, .required)
            .field("h3_hash", .string, .required)
            .field("created", .datetime, .required)
            .field("updated", .datetime, .required)

            // If you intend exactly ONE geolocation row per series, keep this.
            // If you expect multiple geometries per series later, remove it.
            .unique(on: "series_id")

            .create()

        // Postgres-only defaults + indexes
        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE arcus_geolocation
              ALTER COLUMN id SET DEFAULT gen_random_uuid(),
              ALTER COLUMN geometry_hash SET DEFAULT '',
              ALTER COLUMN h3_cells SET DEFAULT '{}'::bigint[],
              ALTER COLUMN h3_resolution SET DEFAULT 8,
              ALTER COLUMN h3_hash SET DEFAULT '',
              ALTER COLUMN created SET DEFAULT now(),
              ALTER COLUMN updated SET DEFAULT now();
        """).run()

        // Fast lookup of “which series are in this H3 cell?”
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS gin_arcus_geolocation_h3_cells
            ON arcus_geolocation USING GIN (h3_cells);
        """).run()

        // Common join path
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_arcus_geolocation_series_id
            ON arcus_geolocation (series_id);
        """).run()
    }

    func revert(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            try await db.schema("arcus_geolocation").delete()
            return
        }

        // Drop indexes first (optional; DROP TABLE will also remove them)
        try await sql.raw("DROP INDEX IF EXISTS gin_arcus_geolocation_h3_cells;").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_arcus_geolocation_series_id;").run()

        try await db.schema(ArcusGeolocationModel.schema).delete()
    }
}
