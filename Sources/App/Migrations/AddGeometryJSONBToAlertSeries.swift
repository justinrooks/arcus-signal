import Fluent
import SQLKit

public struct AddGeometryJSONBToAlertSeries: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        try await database.schema(ArcusSeriesModel.schema)
            .field("geometry", .dictionary)
            .update()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS gin_arcus_series_geometry
            ON arcus_series USING GIN (geometry);
            """).run()
    }

    public func revert(on database: any Database) async throws {
        if let sql = database as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS gin_arcus_series_geometry;").run()
        }

        try await database.schema(ArcusSeriesModel.schema)
            .deleteField("geometry")
            .update()
    }
}
