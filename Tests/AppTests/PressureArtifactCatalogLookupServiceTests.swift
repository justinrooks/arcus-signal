@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Pressure artifact catalog lookup", .serialized)
struct PressureArtifactCatalogLookupServiceTests {
    private func withApp(
        test: (Application, NIOThreadPoolPressureArtifactBlockingWorkExecutor) async throws -> Void
    ) async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                try await clearCatalog(on: app.db)
                let blockingWorkExecutor = makePressureArtifactBlockingWorkExecutor(application: app)
                try await test(app, blockingWorkExecutor)
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

    @Test("exact ready lookup returns the expected local artifact")
    func exactReadyLookupReturnsExpectedLocalArtifact() async throws {
        try await withApp { app, blockingWorkExecutor in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let localFileURL = makeTempRegularFile(contents: Data("ready-artifact".utf8))
            let candidate = HrrrRunCandidate(
                product: .wrfprsf,
                runTime: runTime,
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV2
            )

            try await PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: localFileURL.path,
                byteSize: 14,
                source: .aws
            ).create(on: app.db)

            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor
            )
            let artifact = try await service.readyArtifact(for: candidate)

            #expect(artifact?.runTime == runTime)
            #expect(artifact?.forecastHour == 9)
            #expect(artifact?.validTime == validTime)
            #expect(artifact?.product == .wrfprsf)
            #expect(artifact?.fieldSetVersion == .tornadoPressureV2)
            #expect(artifact?.localFileURL == localFileURL)
            #expect(artifact?.byteSize == 14)
            #expect(artifact?.freshness == .exact)
        }
    }

    @Test("wrong field-set version is not accepted")
    func wrongFieldSetVersionIsNotAccepted() async throws {
        try await withApp { app, blockingWorkExecutor in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let localFileURL = makeTempRegularFile(contents: Data("ready-artifact".utf8))
            let candidate = HrrrRunCandidate(
                product: .wrfprsf,
                runTime: runTime,
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV2
            )

            try await PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV1,
                status: .ready,
                localPath: localFileURL.path,
                byteSize: 14,
                source: .aws
            ).create(on: app.db)

            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor
            )
            let artifact = try await service.readyArtifact(for: candidate)

            #expect(artifact == nil)
        }
    }

    @Test("stale lookup returns the newest eligible valid artifact after exact misses")
    func staleLookupReturnsTheNewestEligibleValidArtifactAfterExactMisses() async throws {
        try await withApp { app, blockingWorkExecutor in
            let targetValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let candidate = HrrrRunCandidate(
                product: .wrfprsf,
                runTime: targetValidTime,
                forecastHour: 0,
                fieldSetVersion: .tornadoPressureV2
            )

            let futureRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(3_600),
                forecastHour: 0,
                validTime: targetValidTime.addingTimeInterval(3_600),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("future".utf8)).path,
                byteSize: 6,
                source: .aws
            )
            let wrongVersionRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-3_600),
                forecastHour: 1,
                validTime: targetValidTime.addingTimeInterval(-3_600),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV1,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("wrong-version".utf8)).path,
                byteSize: 13,
                source: .aws
            )
            let nonReadyRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-7_200),
                forecastHour: 2,
                validTime: targetValidTime.addingTimeInterval(-7_200),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .warming,
                localPath: makeTempRegularFile(contents: Data("warming".utf8)).path,
                byteSize: 7,
                source: .aws
            )
            let missingPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-stale-artifact-\(UUID().uuidString).grib2")
            let missingFileRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-5_400),
                forecastHour: 3,
                validTime: targetValidTime.addingTimeInterval(-5_400),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: missingPath.path,
                byteSize: 9,
                source: .aws
            )
            let zeroByteRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-5_100),
                forecastHour: 4,
                validTime: targetValidTime.addingTimeInterval(-5_100),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data()).path,
                byteSize: 0,
                source: .aws
            )
            let boundaryRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-7_200),
                forecastHour: 5,
                validTime: targetValidTime.addingTimeInterval(-7_200),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("boundary".utf8)).path,
                byteSize: 8,
                source: .aws
            )
            let newestValidRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-3_600),
                forecastHour: 6,
                validTime: targetValidTime.addingTimeInterval(-3_600),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("newest-valid".utf8)).path,
                byteSize: 12,
                source: .aws
            )

            try await futureRow.create(on: app.db)
            try await wrongVersionRow.create(on: app.db)
            try await nonReadyRow.create(on: app.db)
            try await missingFileRow.create(on: app.db)
            try await zeroByteRow.create(on: app.db)
            try await boundaryRow.create(on: app.db)
            try await newestValidRow.create(on: app.db)

            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor
            )
            let artifact = try await service.staleArtifact(
                for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [candidate])
            )

            #expect(artifact?.runTime == newestValidRow.runTime)
            #expect(artifact?.forecastHour == newestValidRow.forecastHour)
            #expect(artifact?.validTime == newestValidRow.validTime)
            #expect(artifact?.freshness == .stale(ageSeconds: 3_600))
        }
    }

    @Test("stale lookup accepts the exact two-hour boundary")
    func staleLookupAcceptsTheExactTwoHourBoundary() async throws {
        try await withApp { app, blockingWorkExecutor in
            let targetValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let candidate = HrrrRunCandidate(
                product: .wrfprsf,
                runTime: targetValidTime,
                forecastHour: 0,
                fieldSetVersion: .tornadoPressureV2
            )

            let boundaryRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-7_200),
                forecastHour: 5,
                validTime: targetValidTime.addingTimeInterval(-7_200),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("boundary".utf8)).path,
                byteSize: 8,
                source: .aws
            )
            let tooOldRow = PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-7_201),
                forecastHour: 6,
                validTime: targetValidTime.addingTimeInterval(-7_201),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("too-old".utf8)).path,
                byteSize: 7,
                source: .aws
            )

            try await boundaryRow.create(on: app.db)
            try await tooOldRow.create(on: app.db)

            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor
            )
            let artifact = try await service.staleArtifact(
                for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [candidate])
            )

            #expect(artifact?.runTime == boundaryRow.runTime)
            #expect(artifact?.forecastHour == boundaryRow.forecastHour)
            #expect(artifact?.validTime == boundaryRow.validTime)
            #expect(artifact?.freshness == .stale(ageSeconds: 7_200))
        }
    }

    @Test("non-ready rows are not accepted")
    func nonReadyRowsAreNotAccepted() async throws {
            try await withApp { app, blockingWorkExecutor in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let localFileURL = makeTempRegularFile(contents: Data("ready-artifact".utf8))
            for (offset, status) in [PressureArtifactCatalogStatus.pending, .warming, .failed, .expired].enumerated() {
                let forecastHour = 9 + offset
                let candidate = HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: runTime,
                    forecastHour: forecastHour,
                    fieldSetVersion: .tornadoPressureV2
                )

                try await PressureArtifactCatalogModel(
                    runTime: runTime,
                    forecastHour: forecastHour,
                    validTime: validTime,
                    product: .wrfprsf,
                    fieldSetVersion: .tornadoPressureV2,
                    status: status,
                    localPath: localFileURL.path,
                    byteSize: 14,
                    source: .aws
                ).create(on: app.db)

                let service = DefaultPressureArtifactCatalogLookupService(
                    database: app.db,
                    blockingWorkExecutor: blockingWorkExecutor
                )
                let artifact = try await service.readyArtifact(for: candidate)

                #expect(artifact == nil)
            }
        }
    }

    @Test("ready rows with unusable local paths are not accepted")
    func readyRowsWithUnusableLocalPathsAreNotAccepted() async throws {
        try await withApp { app, blockingWorkExecutor in
            let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let validTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let candidate = HrrrRunCandidate(
                product: .wrfprsf,
                runTime: runTime,
                forecastHour: 9,
                fieldSetVersion: .tornadoPressureV2
            )
            let missingPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-ready-artifact-\(UUID().uuidString).grib2")
            let directoryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ready-artifact-directory-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let zeroByteURL = makeTempRegularFile(contents: Data())
            let noPathRow = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 9,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                source: .aws
            )
            let missingFileRow = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 10,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: missingPath.path,
                byteSize: 14,
                source: .aws
            )
            let directoryRow = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 11,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: directoryURL.path,
                byteSize: 14,
                source: .aws
            )
            let zeroByteRow = PressureArtifactCatalogModel(
                runTime: runTime,
                forecastHour: 12,
                validTime: validTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: zeroByteURL.path,
                byteSize: 0,
                source: .aws
            )

            try await noPathRow.create(on: app.db)
            try await missingFileRow.create(on: app.db)
            try await directoryRow.create(on: app.db)
            try await zeroByteRow.create(on: app.db)

            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor
            )

            #expect(try await service.readyArtifact(for: candidate) == nil)
            #expect(try await service.readyArtifact(for: candidate.with(forecastHour: 10)) == nil)
            #expect(try await service.readyArtifact(for: candidate.with(forecastHour: 11)) == nil)
            #expect(try await service.readyArtifact(for: candidate.with(forecastHour: 12)) == nil)
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
        let components = DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )

        guard let date = StormSetupUTC.calendar.date(from: components) else {
            preconditionFailure("Unable to create UTC date for test.")
        }

        return date
    }

    private func makeTempRegularFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ready-artifact-\(UUID().uuidString).grib2")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }
}

private extension HrrrRunCandidate {
    func with(forecastHour: Int) -> HrrrRunCandidate {
        HrrrRunCandidate(
            model: model,
            product: product,
            domain: domain,
            runTime: runTime,
            forecastHour: forecastHour,
            fieldSetVersion: fieldSetVersion
        )
    }
}
