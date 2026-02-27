import Fluent
import SQLKit

public struct CreateAlertSeriesModel: AsyncMigration {
    public init() {}
    
    public func prepare(on database: any Database) async throws {
        try await database.schema(ArcusSeriesModel.schema)
            .id()
            .field("source", .string, .required)
            .field("event", .string, .required)
            .field("source_url", .string, .required)
            .field("current_revision_urn", .string, .required)
            .field("current_revision_sent", .datetime, .required)
            .field("message_type", .string, .required)
            .field("content_fingerprint", .string, .required)
            .field("state", .string, .required)
            .field("severity", .string, .required)
            .field("urgency", .string, .required)
            .field("certainty", .string, .required)
            .field("ugc_codes", .array(of: .string), .required)
            .field("created", .datetime, .required)
            .field("updated", .datetime, .required)
            .field("last_seen_active", .datetime, .required)
            .field("sent", .datetime)
            .field("effective", .datetime)
            .field("onset", .datetime)
            .field("expires", .datetime)
            .field("ends", .datetime)
            .field("title", .string)
            .field("area_desc", .string)
        //            .unique(on: "event_key", "revision")
            .create()
        
        // Postgres-only defaults + constraints + indexes + GIN
        guard let sql = database as? any SQLDatabase else { return }
        
        try await sql.raw("""
                    ALTER TABLE alert_series
                      ALTER COLUMN id SET DEFAULT gen_random_uuid(),
                      ALTER COLUMN state SET DEFAULT 'active',
                      ALTER COLUMN created SET DEFAULT now(),
                      ALTER COLUMN updated SET DEFAULT now(),
                      ALTER COLUMN last_seen_active SET DEFAULT now(),
                      ALTER COLUMN ugc_codes SET DEFAULT '{}'::text[],
                      ALTER COLUMN content_fingerprint SET DEFAULT '';
                    """).run()
        
        try await sql.raw("""
                    ALTER TABLE alert_series
                      ADD CONSTRAINT alert_series_state_check
                      CHECK (state IN ('active', 'cancelled_in_error', 'expired'));
                    """).run()
        
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_alert_series_state ON alert_series(state);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_alert_series_expires ON alert_series(expires);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_alert_series_ends ON alert_series(ends);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_alert_series_last_seen_active ON alert_series(last_seen_active);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS gin_alert_series_ugc_codes ON alert_series USING GIN (affected_zones);").run()
        
    }
    
    public func revert(on database: any Database) async throws {
        try await database.schema(ArcusSeriesModel.schema).delete()
    }
}
