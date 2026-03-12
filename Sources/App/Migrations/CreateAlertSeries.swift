import Fluent
import SQLKit

public struct AddRemainingArcusSeriesFields: AsyncMigration {
    public func prepare(on db: any Database) async throws {
        try await db.schema(ArcusSeriesModel.schema)
            .field("category", .string)
            .field("senderName", .string)
            .field("headline", .string)
            .field("description", .string)
            .field("instructions", .string)
            .field("response", .string)
            .field("status", .string)
            .update()
    }

    public func revert(on db: any Database) async throws {
        try await db.schema(ArcusSeriesModel.schema)
            .deleteField("category")
            .deleteField("senderName")
            .deleteField("headline")
            .deleteField("description")
            .deleteField("instructions")
            .deleteField("response")
            .deleteField("status")
            .update()
    }
}

public struct FixArcusSeriesSenderNameField: AsyncMigration {
    public func prepare(on db: any Database) async throws {
        try await db.schema(ArcusSeriesModel.schema)
            .field("sender_name", .string)
            .update()
    }

    public func revert(on db: any Database) async throws {
        try await db.schema(ArcusSeriesModel.schema)
            .deleteField("sender_name")
            .update()
    }
}

public struct RemoveArcusSeriesSenderNameField: AsyncMigration {
    public func prepare(on db: any Database) async throws {
        try await db.schema(ArcusSeriesModel.schema)
            .deleteField("senderName")
            .update()
    }

    public func revert(on db: any Database) async throws {
        // no op
    }
}

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
                    ALTER TABLE arcus_series
                      ALTER COLUMN id SET DEFAULT gen_random_uuid(),
                      ALTER COLUMN state SET DEFAULT 'active',
                      ALTER COLUMN created SET DEFAULT now(),
                      ALTER COLUMN updated SET DEFAULT now(),
                      ALTER COLUMN last_seen_active SET DEFAULT now(),
                      ALTER COLUMN ugc_codes SET DEFAULT '{}'::text[],
                      ALTER COLUMN content_fingerprint SET DEFAULT '';
                    """).run()
        
        try await sql.raw("""
                    ALTER TABLE arcus_series
                      ADD CONSTRAINT alert_series_state_check
                      CHECK (state IN ('active', 'cancelled_in_error', 'expired'));
                    """).run()
        
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_arcus_series_state ON arcus_series(state);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_arcus_series_expires ON arcus_series(expires);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_arcus_series_ends ON arcus_series(ends);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_arcus_series_last_seen_active ON arcus_series(last_seen_active);").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS gin_arcus_series_ugc_codes ON arcus_series USING GIN (ugc_codes);").run()
        
    }
    
    public func revert(on database: any Database) async throws {
        try await database.schema(ArcusSeriesModel.schema).delete()
    }
}
