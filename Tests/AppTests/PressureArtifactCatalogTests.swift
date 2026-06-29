@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Pressure artifact catalog persistence", .serialized)
struct PressureArtifactCatalogTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                try await clearCatalog(on: app.db)
                try await test(app)
            } catch {
                Issue.record("Test DB error: \(String(reflecting: error))")
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    private func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    @Test("migration creates the table and allows inserting a catalog row")
    func migrationCreatesTableAndAcceptsRow() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let created = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .pending,
                source: .unknown
            )
            try await created.create(on: app.db)

            let fetched = try await PressureArtifactCatalogModel.find(
                runTime: runTime,
                forecastHour: 9,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                on: app.db
            )

            #expect(fetched?.id == created.id)
            #expect(fetched?.runTime == runTime)
            #expect(fetched?.validTime == validTime)
            #expect(fetched?.status == .pending)
        }
    }

    @Test("row can be queried by artifact identity")
    func rowCanBeQueriedByArtifactIdentity() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let row = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .warming,
                source: .nomads
            )
            try await row.create(on: app.db)

            let fetched = try await PressureArtifactCatalogModel.find(
                runTime: runTime,
                forecastHour: 9,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                on: app.db
            )

            #expect(fetched?.id == row.id)
            #expect(fetched?.source == .nomads)
            #expect(fetched?.status == .warming)
        }
    }

    @Test("duplicate artifact identity is prevented by the unique constraint")
    func duplicateArtifactIdentityIsRejected() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let first = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: "/tmp/pressure-artifact.grib2",
                byteSize: 1024,
                source: .aws
            )
            try await first.create(on: app.db)

            let duplicate = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .failed,
                source: .nomads
            )

            do {
                try await duplicate.create(on: app.db)
                Issue.record("Expected the duplicate insert to violate the unique constraint.")
            } catch {
                #expect(DbUtils.isUniqueConstraintViolation(error))
            }

            let rows = try await PressureArtifactCatalogModel.query(on: app.db)
                .filter(\.$runTime == runTime)
                .filter(\.$forecastHour == 9)
                .filter(\.$productRaw == HrrrProduct.wrfprsf.rawValue)
                .filter(\.$fieldSetVersionRaw == HrrrFieldSetVersion.tornadoPressureV2.rawValue)
                .all()

            #expect(rows.count == 1)
        }
    }

    @Test("field-set-version separation allows the same artifact identity to coexist across versions")
    func fieldSetVersionSeparationAllowsCoexistence() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let v1 = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV1,
                status: .warming,
                source: .nomads
            )
            let v2 = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                source: .aws
            )

            try await v1.create(on: app.db)
            try await v2.create(on: app.db)

            let rows = try await PressureArtifactCatalogModel.query(on: app.db)
                .filter(\.$runTime == runTime)
                .filter(\.$forecastHour == 9)
                .filter(\.$productRaw == HrrrProduct.wrfprsf.rawValue)
                .all()

            #expect(rows.count == 2)
            #expect(Set(rows.map(\.fieldSetVersion)) == Set([.tornadoPressureV1, .tornadoPressureV2]))
        }
    }

    @Test("status and source raw values round-trip as expected")
    func statusAndSourceRawValuesRoundTrip() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let row = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .failed,
                source: .unknown,
                lastCheckedAt: runTime,
                errorSummary: "upstream timeout"
            )
            try await row.create(on: app.db)

            let fetched = try await PressureArtifactCatalogModel.find(
                runTime: runTime,
                forecastHour: 9,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                on: app.db
            )

            #expect(fetched?.statusRaw == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(fetched?.status == .failed)
            #expect(fetched?.sourceRaw == PressureArtifactCatalogSource.unknown.rawValue)
            #expect(fetched?.source == .unknown)
            #expect(fetched?.lastCheckedAt == runTime)
            #expect(fetched?.errorSummary == "upstream timeout")
        }
    }

    @Test("ready rows can store a local path and byte size")
    func readyRowsStoreLocalPathAndByteSize() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let row = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: "/var/tmp/pressure-artifact.grib2",
                byteSize: 4096,
                source: .aws
            )
            try await row.create(on: app.db)

            let fetched = try await PressureArtifactCatalogModel.find(
                runTime: runTime,
                forecastHour: 9,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                on: app.db
            )

            #expect(fetched?.status == .ready)
            #expect(fetched?.localPath == "/var/tmp/pressure-artifact.grib2")
            #expect(fetched?.byteSize == 4096)
        }
    }

    @Test("pending and warming rows may omit local path and byte size")
    func pendingAndWarmingRowsMayOmitLocalPathAndByteSize() async throws {
        try await withApp { app in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)

            let pending = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .pending
            )
            let warming = PressureArtifactCatalogModel(
                runTime: runTime.addingTimeInterval(3600),
                forecastHour: 10,
                validTime: validTime.addingTimeInterval(3600),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .warming
            )

            try await pending.create(on: app.db)
            try await warming.create(on: app.db)

            let rows = try await PressureArtifactCatalogModel.query(on: app.db)
                .filter(\.$productRaw == HrrrProduct.wrfprsf.rawValue)
                .all()

            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.localPath == nil && $0.byteSize == nil })
        }
    }
}

private func makeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    var components = DateComponents()
    components.calendar = Calendar(identifier: .gregorian)
    components.timeZone = TimeZone(secondsFromGMT: 0)
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = second
    return components.date ?? .now
}
