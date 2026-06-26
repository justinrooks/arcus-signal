import Fluent
import SQLKit

struct CreatePressureArtifactCatalog: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(PressureArtifactCatalogModel.schema)
            .id()
            .field("run_time", .datetime, .required)
            .field("forecast_hour", .int, .required)
            .field("valid_time", .datetime, .required)
            .field("product", .string, .required)
            .field("field_set_version", .string, .required)
            .field("status", .string, .required)
            .field("local_path", .string)
            .field("byte_size", .int64)
            .field("source", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .field("last_checked_at", .datetime)
            .field("error_summary", .string)
            .unique(on: "run_time", "forecast_hour", "product", "field_set_version")
            .create()

        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_pressure_artifact_catalog_status
            ON pressure_artifact_catalog (status);
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_pressure_artifact_catalog_status_updated_at
            ON pressure_artifact_catalog (status, updated_at);
            """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_pressure_artifact_catalog_status_updated_at;").run()
            try await sql.raw("DROP INDEX IF EXISTS idx_pressure_artifact_catalog_status;").run()
        }

        try await db.schema(PressureArtifactCatalogModel.schema).delete()
    }
}
