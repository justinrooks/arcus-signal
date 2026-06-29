@testable import App
import Fluent
import FluentSQL
import Foundation
import Dispatch
import Testing
import Vapor

@Suite("Pressure artifact cleanup service", .serialized)
struct PressureArtifactCleanupServiceTests {
    @Test("old ready rows expire first and are not deleted in the same run")
    func oldReadyRowsExpireFirstAndAreNotDeletedInTheSameRun() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let expiredRow = try await seedRow(
                on: app.db,
                status: .ready,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 59),
                localPath: makeTempRegularFile(in: rootURL, name: "old-ready.grib2", contents: Data("old".utf8)).path,
                byteSize: 3
            )
            let boundaryRow = try await seedRow(
                on: app.db,
                status: .ready,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                localPath: makeTempRegularFile(in: rootURL, name: "boundary-ready.grib2", contents: Data("boundary".utf8)).path,
                byteSize: 8
            )

            try await service.cleanup(on: app, logger: app.logger)

            let expiredRefreshed = try #require(try await PressureArtifactCatalogModel.find(expiredRow.id, on: app.db))
            let boundaryRefreshed = try #require(try await PressureArtifactCatalogModel.find(boundaryRow.id, on: app.db))

            #expect(expiredRefreshed.status == .expired)
            #expect(expiredRefreshed.localPath != nil)
            #expect(expiredRefreshed.byteSize == 3)
            #expect(FileManager.default.fileExists(atPath: expiredRefreshed.localPath!))
            #expect(boundaryRefreshed.status == .ready)
            #expect(boundaryRefreshed.localPath != nil)
            #expect(FileManager.default.fileExists(atPath: boundaryRefreshed.localPath!))
        }
    }

    @Test("pre-expired rows older than the grace period are deleted")
    func preExpiredRowsOlderThanTheGracePeriodAreDeleted() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let fileURL = makeTempRegularFile(in: rootURL, name: "expired.grib2", contents: Data("expired".utf8))
            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: fileURL.path,
                byteSize: 7
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.status == .expired)
            #expect(refreshed.localPath == nil)
            #expect(refreshed.byteSize == nil)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("only one cleanup token owns a candidate")
    func onlyOneCleanupTokenOwnsACandidate() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let fileURL = makeTempRegularFile(in: rootURL, name: "concurrent.grib2", contents: Data("delete-me".utf8))
            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: fileURL.path,
                byteSize: 9
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            let deletionCutoff = now.addingTimeInterval(-60 * 60)
            let cleanupLeaseExpiresAt = makeUTCDate(year: 2026, month: 6, day: 30, hour: 22)
            let firstClaim = try #require(try await service.claimDeletionCandidate(
                for: row,
                olderThan: deletionCutoff,
                cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
                on: app.db
            ))
            let secondClaim = try await service.claimDeletionCandidate(
                for: row,
                olderThan: deletionCutoff,
                cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
                on: app.db
            )

            #expect(firstClaim.claimToken != nil)
            #expect(firstClaim.leaseExpiresAt == cleanupLeaseExpiresAt)
            #expect(secondClaim == nil)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("expired cleanup leases can be reclaimed")
    func expiredCleanupLeasesCanBeReclaimed() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let fileURL = makeTempRegularFile(in: rootURL, name: "reclaim.grib2", contents: Data("reclaim".utf8))
            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: fileURL.path,
                byteSize: 7,
                claimToken: UUID(),
                leaseExpiresAt: now.addingTimeInterval(-60)
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == nil)
            #expect(refreshed.byteSize == nil)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("old cleanup tokens cannot clear metadata after ownership changes")
    func oldCleanupTokensCannotClearMetadataAfterOwnershipChanges() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let fileURL = makeTempRegularFile(in: rootURL, name: "ownership.grib2", contents: Data("ownership".utf8))
            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: fileURL.path,
                byteSize: 9
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            let deletionCutoff = now.addingTimeInterval(-60 * 60)
            let cleanupLeaseExpiresAt = now.addingTimeInterval(30 * 60)
            let claimedRow = try #require(try await service.claimDeletionCandidate(
                for: row,
                olderThan: deletionCutoff,
                cleanupLeaseExpiresAt: cleanupLeaseExpiresAt,
                on: app.db
            ))
            let oldClaimToken = try #require(claimedRow.claimToken)
            let newClaimToken = UUID()
            try await reclaimCleanupOwnership(
                on: app.db,
                rowID: try #require(row.id),
                claimToken: newClaimToken,
                leaseExpiresAt: makeUTCDate(year: 2026, month: 6, day: 30, hour: 22)
            )

            let didFinish = try await service.completeSuccessfulCleanup(
                for: claimedRow,
                claimToken: oldClaimToken,
                on: app.db
            )

            #expect(didFinish == false)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == fileURL.path)
            #expect(refreshed.byteSize == 9)
            #expect(refreshed.claimToken == newClaimToken)
            #expect(refreshed.leaseExpiresAt != nil)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("warming rows and boundary ready rows remain untouched")
    func warmingRowsAndBoundaryReadyRowsRemainUntouched() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let warmingURL = makeTempRegularFile(in: rootURL, name: "warming.grib2", contents: Data("warming".utf8))
            let boundaryURL = makeTempRegularFile(in: rootURL, name: "boundary.grib2", contents: Data("boundary".utf8))
            let protectedExpiredRow = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: warmingURL.path,
                byteSize: 7
            )
            let warmingRow = try await seedRow(
                on: app.db,
                status: .warming,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19),
                localPath: warmingURL.path,
                byteSize: 7
            )
            let boundaryRow = try await seedRow(
                on: app.db,
                status: .ready,
                validTime: now.addingTimeInterval(-7_200),
                localPath: boundaryURL.path,
                byteSize: 8
            )
            try await backdateRow(protectedExpiredRow, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let protectedExpiredRefreshed = try #require(try await PressureArtifactCatalogModel.find(protectedExpiredRow.id, on: app.db))
            let warmingRefreshed = try #require(try await PressureArtifactCatalogModel.find(warmingRow.id, on: app.db))
            let boundaryRefreshed = try #require(try await PressureArtifactCatalogModel.find(boundaryRow.id, on: app.db))

            #expect(protectedExpiredRefreshed.status == .expired)
            #expect(protectedExpiredRefreshed.localPath == warmingURL.path)
            #expect(protectedExpiredRefreshed.byteSize == 7)
            #expect(protectedExpiredRefreshed.claimToken == nil)
            #expect(protectedExpiredRefreshed.leaseExpiresAt == nil)
            #expect(warmingRefreshed.status == .warming)
            #expect(warmingRefreshed.localPath == warmingURL.path)
            #expect(warmingRefreshed.byteSize == 7)
            #expect(FileManager.default.fileExists(atPath: warmingURL.path))
            #expect(boundaryRefreshed.status == .ready)
            #expect(boundaryRefreshed.localPath == boundaryURL.path)
            #expect(boundaryRefreshed.byteSize == 8)
            #expect(FileManager.default.fileExists(atPath: boundaryURL.path))
        }
    }

    @Test("shared paths referenced by ready rows are not deleted")
    func sharedPathsReferencedByReadyRowsAreNotDeleted() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let sharedURL = makeTempRegularFile(in: rootURL, name: "shared.grib2", contents: Data("shared".utf8))
            let expiredRow = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: sharedURL.path,
                byteSize: 6
            )
            let readyRow = try await seedRow(
                on: app.db,
                status: .ready,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                localPath: sharedURL.path,
                byteSize: 6
            )

            try await backdateRow(expiredRow, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let expiredRefreshed = try #require(try await PressureArtifactCatalogModel.find(expiredRow.id, on: app.db))
            let readyRefreshed = try #require(try await PressureArtifactCatalogModel.find(readyRow.id, on: app.db))

            #expect(expiredRefreshed.status == .expired)
            #expect(expiredRefreshed.localPath == sharedURL.path)
            #expect(expiredRefreshed.byteSize == 6)
            #expect(expiredRefreshed.errorSummary == nil)
            #expect(expiredRefreshed.claimToken == nil)
            #expect(expiredRefreshed.leaseExpiresAt == nil)
            #expect(FileManager.default.fileExists(atPath: sharedURL.path))
            #expect(readyRefreshed.status == .ready)
            #expect(readyRefreshed.localPath == sharedURL.path)
            #expect(readyRefreshed.byteSize == 6)
            #expect(FileManager.default.fileExists(atPath: sharedURL.path))
        }
    }

    @Test("missing files are handled idempotently")
    func missingFilesAreHandledIdempotently() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let missingURL = rootURL.appendingPathComponent("missing.grib2")
            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: missingURL.path,
                byteSize: 7
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == nil)
            #expect(refreshed.byteSize == nil)
            #expect(refreshed.status == .expired)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
        }
    }

    @Test("deletion failures release the cleanup claim and preserve metadata")
    func deletionFailuresReleaseTheCleanupClaimAndPreserveMetadata() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let lockedDirectoryURL = rootURL.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: lockedDirectoryURL, withIntermediateDirectories: true)
            let fileURL = lockedDirectoryURL.appendingPathComponent("locked.grib2")
            FileManager.default.createFile(atPath: fileURL.path, contents: Data("locked".utf8))
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: lockedDirectoryURL.path
                )
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: lockedDirectoryURL.path
            )

            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: fileURL.path,
                byteSize: 6
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == fileURL.path)
            #expect(refreshed.byteSize == 6)
            #expect(refreshed.errorSummary?.contains("cleanup delete failed") == true)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
            #expect(FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("directories remain protected")
    func directoriesRemainProtected() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let directoryURL = rootURL.appendingPathComponent("artifact-dir", isDirectory: true)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: directoryURL.path,
                byteSize: 0
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == directoryURL.path)
            #expect(refreshed.byteSize == 0)
            #expect(refreshed.errorSummary?.contains("not a regular file") == true)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
            #expect(FileManager.default.fileExists(atPath: directoryURL.path))
        }
    }

    @Test("paths outside the cache root are never deleted")
    func pathsOutsideTheCacheRootAreNeverDeleted() async throws {
        try await withApp { app, rootURL in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let service = makeService(rootURL: rootURL, now: now)
            let outsideURL = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).grib2")
            FileManager.default.createFile(atPath: outsideURL.path, contents: Data("outside".utf8))
            let symlinkURL = rootURL.appendingPathComponent("outside-link.grib2")
            try FileManager.default.createSymbolicLink(atPath: symlinkURL.path, withDestinationPath: outsideURL.path)

            let row = try await seedRow(
                on: app.db,
                status: .expired,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                localPath: symlinkURL.path,
                byteSize: 7
            )
            try await backdateRow(row, updatedAt: now.addingTimeInterval(-7_200), on: app.db)

            try await service.cleanup(on: app, logger: app.logger)

            let refreshed = try #require(try await PressureArtifactCatalogModel.find(row.id, on: app.db))
            #expect(refreshed.localPath == symlinkURL.path)
            #expect(refreshed.byteSize == 7)
            #expect(refreshed.errorSummary?.contains("outside cache root") == true)
            #expect(refreshed.claimToken == nil)
            #expect(refreshed.leaseExpiresAt == nil)
            #expect(FileManager.default.fileExists(atPath: outsideURL.path))
        }
    }
}

private extension PressureArtifactCleanupServiceTests {
    func withApp(test: (Application, URL) async throws -> Void) async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("pressure-cleanup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                try await clearCatalog(on: app.db)
                try await test(app, rootURL)
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    func makeService(rootURL: URL, now: Date) -> PressureArtifactCleanupService {
        makeService(rootURL: rootURL, now: now, beforePhysicalRemovalHook: {})
    }

    func makeService(
        rootURL: URL,
        now: Date,
        beforePhysicalRemovalHook: @escaping @Sendable () async -> Void
    ) -> PressureArtifactCleanupService {
        PressureArtifactCleanupService(
            dateProvider: FixedCleanupDateProvider(nowDate: now),
            cacheRootURL: rootURL,
            maxStaleAgeSeconds: 2 * 60 * 60,
            deleteGraceSeconds: 60 * 60,
            recoveryTimeoutSeconds: 30 * 60,
            beforePhysicalRemovalHook: beforePhysicalRemovalHook
        )
    }

    func seedRow(
        on db: any Database,
        status: PressureArtifactCatalogStatus,
        validTime: Date,
        localPath: String,
        byteSize: Int64,
        claimToken: UUID? = nil,
        leaseExpiresAt: Date? = nil
    ) async throws -> PressureArtifactCatalogModel {
        let row = PressureArtifactCatalogModel(
            runTime: validTime.addingTimeInterval(-3_600),
            forecastHour: 0,
            validTime: validTime,
            product: .wrfprsf,
            fieldSetVersion: .tornadoPressureV2,
            status: status,
            localPath: localPath,
            byteSize: byteSize,
            claimToken: claimToken,
            leaseExpiresAt: leaseExpiresAt,
            source: .aws
        )
        try await row.create(on: db)
        return row
    }

    func makeTempRegularFile(
        in rootURL: URL,
        name: String,
        contents: Data
    ) -> URL {
        let url = rootURL.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }

    func backdateRow(
        _ row: PressureArtifactCatalogModel,
        updatedAt: Date,
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        guard let id = row.id else {
            throw Abort(.internalServerError, reason: "Seeded catalog row is missing an id.")
        }

        try await sql.raw(
            "UPDATE pressure_artifact_catalog SET updated_at = \(bind: updatedAt) WHERE id = \(bind: id);"
        ).run()
    }

    func makeUTCDate(
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

    func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    func reclaimCleanupOwnership(
        on db: any Database,
        rowID: UUID,
        claimToken: UUID,
        leaseExpiresAt: Date
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET claim_token = \(bind: claimToken),
                lease_expires_at = \(bind: leaseExpiresAt)
            WHERE id = \(bind: rowID)
              AND status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
            """).run()
    }
}

private struct FixedCleanupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}
