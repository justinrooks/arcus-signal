import Fluent
import SQLKit

struct AddClaimFencingToPressureArtifactCatalog: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(PressureArtifactCatalogModel.schema)
            .field("claim_token", .uuid)
            .field("lease_expires_at", .datetime)
            .update()

        guard let sql = db as? any SQLDatabase else { return }

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_pressure_artifact_catalog_claim_token
            ON pressure_artifact_catalog (claim_token);
            """).run()
    }

    func revert(on db: any Database) async throws {
        if let sql = db as? any SQLDatabase {
            try await sql.raw("DROP INDEX IF EXISTS idx_pressure_artifact_catalog_claim_token;").run()
        }

        try await db.schema(PressureArtifactCatalogModel.schema)
            .deleteField("claim_token")
            .deleteField("lease_expires_at")
            .update()
    }
}
