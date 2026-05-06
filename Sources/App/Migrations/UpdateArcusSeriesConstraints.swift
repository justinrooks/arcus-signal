//
//  UpdateArcusSeriesConstraints.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/23/26.
//

import Fluent
import SQLKit

public struct UpdateArcusSeriesConstraints: AsyncMigration {
    public init() {}
    
    public func prepare(on database: any Database) async throws {
        // Postgres-only defaults + constraints + indexes + GIN
        guard let sql = database as? any SQLDatabase else { return }
        
        try await sql.raw("""
                    ALTER TABLE arcus_series
                      DROP CONSTRAINT IF EXISTS alert_series_state_check;
                    """).run()
        
        try await sql.raw("""
                    DO $$
                    BEGIN
                      IF NOT EXISTS (
                        SELECT 1
                        FROM pg_constraint
                        WHERE conname = 'alert_series_state_check'
                      ) THEN
                        ALTER TABLE arcus_series
                          ADD CONSTRAINT alert_series_state_check
                          CHECK (state IN ('active', 'cancelled_in_error', 'cancelled', 'ended', 'expired'));
                      END IF;
                    END
                    $$;
                    """).run()
    }
    
    public func revert(on database: any Database) async throws {
        // NO op
    }
}
