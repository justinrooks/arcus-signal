import Fluent
import FluentSQL
import Foundation
import Vapor

enum InstallationActivityDailySchema {
    static let name = "installation_activity_daily"
}

struct InstallationActivityDailyStore: Sendable {
    @discardableResult
    func record(
        installationID: UUID,
        receivedAt: Date,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            INSERT INTO installation_activity_daily
                (installation_id, activity_date, created_at)
            VALUES
                (
                    \(bind: installationID),
                    (\(bind: receivedAt)::timestamptz AT TIME ZONE 'UTC')::date,
                    \(bind: receivedAt)
                )
            ON CONFLICT (installation_id, activity_date) DO NOTHING
            RETURNING installation_id
            """).first()

        return row != nil
    }
}
