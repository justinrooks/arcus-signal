import Fluent
import SQLKit

struct CreateInstallationActivityDaily: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(InstallationActivityDailySchema.name)
            .field("installation_id", .uuid, .required)
            .field("activity_date", .date, .required)
            .field("created_at", .datetime, .required)
            .unique(on: "installation_id", "activity_date")
            .create()

        guard let sql = database as? any SQLDatabase else { return }
        try await sql.raw("""
            ALTER TABLE installation_activity_daily
              ALTER COLUMN created_at SET DEFAULT now();
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(InstallationActivityDailySchema.name).delete()
    }
}
