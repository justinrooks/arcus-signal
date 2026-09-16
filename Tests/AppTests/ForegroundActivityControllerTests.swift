@testable import App
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Foreground activity endpoint", .serialized)
struct ForegroundActivityControllerTests {
    private struct RequestBody: Content {
        let installationId: String
    }

    private func withApp(
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func submit(
        installationID: String,
        to app: Application,
        expecting status: HTTPResponseStatus = .noContent
    ) async throws {
        try await app.testing().test(
            .POST,
            "api/v1/devices/foreground-activity",
            beforeRequest: { request in
                try request.content.encode(RequestBody(installationId: installationID))
            },
            afterResponse: { response async in
                #expect(response.status == status)
            }
        )
    }

    private func activityDates(
        for installationID: UUID,
        in app: Application
    ) async throws -> [String] {
        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let rows = try await sql.raw("""
            SELECT activity_date::text AS activity_date
            FROM installation_activity_daily
            WHERE installation_id = \(bind: installationID)
            ORDER BY activity_date
            """).all()

        return try rows.map { try $0.decode(column: "activity_date", as: String.self) }
    }

    @Test("first activity creates one fact and same-day repeats are idempotent")
    func recordsOneDailyFact() async throws {
        try await withApp { app in
            let installationID = UUID()

            try await submit(installationID: installationID.uuidString, to: app)
            try await submit(installationID: installationID.uuidString, to: app)

            #expect(try await activityDates(for: installationID, in: app).count == 1)
            #expect(try await DeviceInstallationModel.find(installationID, on: app.db) == nil)
            #expect(try await DevicePresenceModel.find(installationID, on: app.db) == nil)
        }
    }

    @Test("UTC date normalization creates a new fact after midnight")
    func normalizesActivityDateInUTC() async throws {
        try await withApp { app in
            let installationID = UUID()
            let beforeMidnight = try #require(
                ISO8601DateFormatter().date(from: "2026-09-16T23:59:59Z")
            )
            let afterMidnight = try #require(
                ISO8601DateFormatter().date(from: "2026-09-17T00:00:00Z")
            )
            let store = InstallationActivityDailyStore()

            #expect(try await store.record(
                installationID: installationID,
                receivedAt: beforeMidnight,
                on: app.db
            ))
            #expect(try await store.record(
                installationID: installationID,
                receivedAt: afterMidnight,
                on: app.db
            ))

            #expect(try await activityDates(for: installationID, in: app) == [
                "2026-09-16",
                "2026-09-17"
            ])
        }
    }

    @Test("malformed installation identifiers are rejected")
    func rejectsMalformedInstallationID() async throws {
        try await withApp { app in
            try await submit(
                installationID: "not-a-uuid",
                to: app,
                expecting: .badRequest
            )
        }
    }

    @Test("persistence failures return an error and do not create a fact")
    func reportsPersistenceFailure() async throws {
        try await withApp { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let installationID = UUID()

            try await sql.raw("""
                ALTER TABLE installation_activity_daily
                ADD CONSTRAINT installation_activity_daily_test_reject
                CHECK (installation_id <> '\(unsafeRaw: installationID.uuidString)'::uuid) NOT VALID
                """).run()
            do {
                try await submit(
                    installationID: installationID.uuidString,
                    to: app,
                    expecting: .internalServerError
                )
            } catch {
                try? await sql.raw("""
                    ALTER TABLE installation_activity_daily
                    DROP CONSTRAINT installation_activity_daily_test_reject
                    """).run()
                throw error
            }
            try await sql.raw("""
                ALTER TABLE installation_activity_daily
                DROP CONSTRAINT installation_activity_daily_test_reject
                """).run()

            #expect(try await activityDates(for: installationID, in: app).isEmpty)
        }
    }
}
