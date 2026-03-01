import Fluent
import SQLKit

public struct EnforceContentFingerprintIntegrityOnAlertSeries: AsyncMigration {
    public init() {}

    public func prepare(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("""
            ALTER TABLE arcus_series
              ALTER COLUMN content_fingerprint DROP DEFAULT;
            """).run()

        try await sql.raw("""
            ALTER TABLE arcus_series
              ADD CONSTRAINT arcus_series_content_fingerprint_hex_check
              CHECK (content_fingerprint ~ '^[0-9a-f]{64}$') NOT VALID;
            """).run()

        try await sql.raw("""
            CREATE INDEX IF NOT EXISTS idx_arcus_series_content_fingerprint
            ON arcus_series(content_fingerprint);
            """).run()
    }

    public func revert(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else { return }

        try await sql.raw("DROP INDEX IF EXISTS idx_arcus_series_content_fingerprint;").run()

        try await sql.raw("""
            ALTER TABLE arcus_series
              DROP CONSTRAINT IF EXISTS arcus_series_content_fingerprint_hex_check;
            """).run()

        try await sql.raw("""
            ALTER TABLE arcus_series
              ALTER COLUMN content_fingerprint SET DEFAULT '';
            """).run()
    }
}
