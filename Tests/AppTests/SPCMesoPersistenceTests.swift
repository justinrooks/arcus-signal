@testable import App
import ArcusCore
import Fluent
import Foundation
import SQLKit
import Testing
import Vapor

@Suite("SPC meso persistence", .serialized)
struct SPCMesoPersistenceTests {
    private enum Rollback: Error { case afterAssertions }

    private func withDatabase(_ test: @escaping @Sendable (any Database, any SQLDatabase) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            do {
                try await app.db.transaction { db in
                    let sql = try #require(db as? any SQLDatabase)
                    try await sql.raw("LOCK TABLE spc_mesos, spc_meso_geolocation IN ACCESS EXCLUSIVE MODE").run()
                    try await test(db, sql)
                    throw Rollback.afterAssertions
                }
            } catch Rollback.afterAssertions {}
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    // Failure atomicity must use real transactions: Fluent reuses an enclosing
    // transaction instead of introducing nested savepoints.
    private func withCoverageDatabase(_ test: @escaping @Sendable (any Database, any SQLDatabase) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        let keys = ["SPC-MD-1803-123", "SPC-MD-1803-124"]
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            let sql = try #require(app.db as? any SQLDatabase)
            try #require(try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ keys).count() == 0)
            do { try await test(app.db, sql) }
            catch {
                try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ keys).delete()
                throw error
            }
            try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ keys).delete()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func product(year: Int = 2025, watchText: String = "80") throws -> MesoscaleDiscussionPayload {
        let url = try #require(Bundle.module.url(forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"))
        var xml = try String(contentsOf: url, encoding: .utf8)
        if year == 2026 {
            xml = xml.replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Thu Dec 31 2026")
        }
        if watchText != "80" {
            xml = xml.replacingOccurrences(of: "Probability of Watch Issuance...80 percent", with: "")
                .replacingOccurrences(of: "Severe potential...Watch likely", with: watchText == "Unlikely" ? "Watch unlikely" : "Severe potential")
        }
        return try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
    }

    private func expectRejected(on sql: any SQLDatabase, operation: () async throws -> Void) async throws {
        try await sql.raw("SAVEPOINT expected_rejection").run()
        var rejected = false
        do { try await operation() } catch { rejected = true }
        try await sql.raw("ROLLBACK TO SAVEPOINT expected_rejection").run()
        try await sql.raw("RELEASE SAVEPOINT expected_rejection").run()
        #expect(rejected)
    }

    private func feed(_ replacing: String = "Severe storms possible.") throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"))
        return Data(try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "Severe storms possible.", with: replacing).utf8)
    }

    @Test func acceptedFeedReplayChangeAbsenceAndExpiry() async throws {
        try await withDatabase { db, _ in
            let service = SPCMesoIngestPersistence()
            let payload = try product()
            let firstSeen = payload.validStart
            let first = try await service.persistFeed(feed(), on: db, seenAt: firstSeen)
            #expect(first.inserted == 1)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == payload.productID).first())
            let id = try row.requireID()
            let fingerprint = row.contentFingerprint
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).first())
            geo.h3Cells = [123]
            geo.h3Resolution = 8
            geo.h3Hash = "coverage"
            try await geo.update(on: db)
            let replayTime = firstSeen.addingTimeInterval(60)
            let replay = try await service.persistFeed(feed(), on: db, seenAt: replayTime)
            #expect(replay.unchanged == 1)
            #expect(replay.inserted == 0 && replay.updated == 0)
            let replayed = try #require(try await SPCMesoModel.find(id, on: db))
            #expect(replayed.contentFingerprint == fingerprint)
            #expect(replayed.firstSeen == firstSeen && replayed.lastSeen == replayTime)
            let changedTime = replayTime.addingTimeInterval(60)
            let changedFeed = try feed("Updated severe potential.")
            let changed = try await service.persistFeed(changedFeed, on: db, seenAt: changedTime)
            #expect(changed.updated == 1)
            let updated = try #require(try await SPCMesoModel.find(id, on: db))
            #expect(updated.summary.contains("Updated severe potential."))
            #expect(updated.contentFingerprint != fingerprint)
            #expect(updated.firstSeen == firstSeen && updated.lastSeen == changedTime)
            let sameGeometry = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(sameGeometry.h3Cells == [123] && sameGeometry.h3Hash == "coverage")
            let absent = try await service.persistFeed(Data("<rss><channel></channel></rss>".utf8), on: db, seenAt: payload.validEnd)
            #expect(absent.inserted == 0 && absent.updated == 0 && absent.unchanged == 0)
            let retained = try #require(try await SPCMesoModel.find(id, on: db))
            #expect(retained.lastSeen == changedTime)
            #expect(!retained.isActive(asOf: firstSeen.addingTimeInterval(-1)))
            #expect(retained.isActive(asOf: firstSeen))
            #expect(retained.isActive(asOf: payload.validEnd.addingTimeInterval(-1)))
            #expect(!retained.isActive(asOf: payload.validEnd))
            let expiredReplay = try await service.persistFeed(changedFeed, on: db, seenAt: payload.validEnd)
            #expect(expiredReplay.unchanged == 1)
            #expect(try await SPCMesoModel.query(on: db).filter(\.$productKey == payload.productID).count() == 1)
            #expect(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).count() == 1)
        }
    }

    @Test func geometryChangesReplaceCoverageAndRemovalDeletesIt() async throws {
        try await withDatabase { db, _ in
            let service = SPCMesoIngestPersistence()
            let payload = try product()
            _ = try await service.persistFeed(feed(), on: db, seenAt: payload.validStart)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == payload.productID).first())
            let id = try row.requireID()
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).first())
            let oldHash = geo.geometryHash
            geo.h3Cells = [123]
            geo.h3Resolution = 8
            geo.h3Hash = "coverage"
            try await geo.update(on: db)
            let xml = try String(decoding: feed(), as: UTF8.self)
            _ = try await service.persistFeed(Data(xml.replacingOccurrences(of: "40000200", with: "41000200").utf8), on: db, seenAt: payload.validStart.addingTimeInterval(60))
            let changed = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(changed.geometryHash != oldHash)
            #expect(changed.geometry != geo.geometry)
            let expected = try SPCMesoCoverage.build(for: changed.geometry)
            #expect(changed.h3Cells == expected.cells && !changed.h3Cells.isEmpty)
            #expect(changed.h3Resolution == 8 && changed.h3Hash == expected.h3Hash)
            let noGeometry = xml.replacingOccurrences(of: "LAT...LON 39000288 40000200 38500100 39000288", with: "")
            _ = try await service.persistFeed(Data(noGeometry.utf8), on: db, seenAt: payload.validStart.addingTimeInterval(120))
            #expect(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).count() == 0)
            #expect(try await SPCMesoModel.find(id, on: db) != nil)
        }
    }

    @Test func coverageReplayBackfillAndFailureAreAtomic() async throws {
        try await withCoverageDatabase { db, sql in
            let xml = String(decoding: try feed(), as: UTF8.self)
                .replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Sat Dec 31 1803")
            let payload = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
            let service = SPCMesoIngestPersistence()
            _ = try await service.persist([payload], on: db, seenAt: payload.validStart)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == payload.productID).first())
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == row.requireID()).first())
            let expected = try SPCMesoCoverage.build(for: geo.geometry)
            #expect(geo.h3Cells == expected.cells && !geo.h3Cells.isEmpty)
            #expect(geo.geometryHash == expected.geometryHash && geo.h3Hash == expected.h3Hash)
            #expect(geo.h3Resolution == 8)
            // ctid detects any geolocation rewrite, even when field values are identical.
            struct Version: Decodable { let version: String }
            func version() async throws -> String {
                try #require(try await sql.raw("SELECT ctid::text AS version FROM spc_meso_geolocation WHERE id = \(bind: geo.requireID())")
                    .first(decoding: Version.self)).version
            }
            let before = try await version()
            let failing = SPCMesoIngestPersistence(buildCoverage: { _ in
                throw SPCMesoCoverageError.generationFailed("injected failure")
            })
            // Completed unchanged coverage never invokes the expensive builder.
            _ = try await failing.persist([payload], on: db, seenAt: payload.validStart.addingTimeInterval(60))
            #expect(try await version() == before)
            geo.h3Cells = []
            geo.h3Hash = nil
            geo.h3Resolution = nil
            try await geo.update(on: db)
            _ = try await service.persist([payload], on: db, seenAt: payload.validStart.addingTimeInterval(120))
            let filled = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(filled.h3Cells == expected.cells && filled.h3Hash == expected.h3Hash)
            let accepted = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            let changedXML = xml.replacingOccurrences(of: "40000200", with: "41000200")
            var reason = ""
            do { _ = try await failing.persistFeed(Data(changedXML.utf8), on: db, seenAt: payload.validStart.addingTimeInterval(180)) }
            catch let error as Abort { reason = error.reason }
            #expect(reason.contains(payload.productID) && reason.contains("injected failure"))
            let malformedXML = xml
                .replacingOccurrences(of: "0123", with: "0124")
                .replacingOccurrences(of: "LAT...LON 39000288 40000200 38500100 39000288", with: "LAT...LON 39000300 41000100 41000300 39000000 39000300")
            let malformed = try #require(SPCMesoParser.parse(Data(malformedXML.utf8)).first)
            let changed = try #require(SPCMesoParser.parse(Data(changedXML.utf8)).first)
            reason = ""
            do { _ = try await service.persist([changed, malformed], on: db, seenAt: payload.validStart.addingTimeInterval(180)) }
            catch let error as Abort { reason = error.reason }
            #expect(reason.contains(malformed.productID) && reason.contains("invalidPolygon"))
            #expect(try await SPCMesoModel.query(on: db).filter(\.$productKey == malformed.productID).count() == 0)
            let retained = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            let retainedGeo = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(retained.contentFingerprint == accepted.contentFingerprint && retained.lastSeen == accepted.lastSeen)
            #expect(retainedGeo.geometry == filled.geometry && retainedGeo.h3Cells == filled.h3Cells)
            #expect(retainedGeo.h3Hash == filled.h3Hash && retainedGeo.geometryHash == filled.geometryHash)
        }
    }

    @Test func rejectedFeedAndConflictingIdentitiesLeaveSnapshotUntouched() async throws {
        try await withDatabase { db, _ in
            let service = SPCMesoIngestPersistence()
            let payload = try product()
            _ = try await service.persist([payload, payload], on: db, seenAt: payload.validStart)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == payload.productID).first())
            let changed = try #require(SPCMesoParser.parse(feed("Changed.")).first)
            var rejected = false
            do { _ = try await service.persist([payload, changed], on: db, seenAt: payload.validEnd) }
            catch { rejected = true }
            #expect(rejected)
            // A valid changed item preceding a malformed recognized MD must not be accepted.
            let mixed = String(decoding: try feed("Changed."), as: UTF8.self)
                .replacingOccurrences(of: "</channel>", with: "<item><title>SPC MD 0999</title></item></channel>")
            rejected = false
            do { _ = try await service.persistFeed(Data(mixed.utf8), on: db, seenAt: payload.validEnd) }
            catch { rejected = true }
            #expect(rejected)
            let retained = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            #expect(retained.contentFingerprint == row.contentFingerprint)
            #expect(retained.summary == row.summary)
            #expect(retained.firstSeen == row.firstSeen && retained.lastSeen == row.lastSeen)
        }
    }

    @Test func olderAndEqualTimeConflictsHaveDeterministicWinner() async throws {
        try await withDatabase { db, _ in
            let service = SPCMesoIngestPersistence()
            let original = try product()
            let correctedXML = String(decoding: try feed("Corrected."), as: UTF8.self)
                .replacingOccurrences(of: "40000200", with: "41000200")
            let corrected = try #require(SPCMesoParser.parse(Data(correctedXML.utf8)).first)
            let later = original.validStart.addingTimeInterval(120)
            _ = try await service.persist([corrected], on: db, seenAt: later)
            let row = try #require(try await SPCMesoModel.query(on: db).filter(\.$productKey == original.productID).first())
            let geo = try #require(try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == row.requireID()).first())
            geo.h3Cells = [123]
            geo.h3Resolution = 8
            geo.h3Hash = "coverage"
            try await geo.update(on: db)
            let stale = try await service.persist([original], on: db, seenAt: original.validStart)
            #expect(stale.ignored == 1)
            let retained = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            let retainedGeo = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(retained.summary == corrected.summary && retained.lastSeen == later)
            #expect(retained.contentFingerprint == row.contentFingerprint)
            #expect(retainedGeo.geometry == geo.geometry && retainedGeo.h3Cells == [123])
            #expect(retainedGeo.h3Resolution == 8 && retainedGeo.h3Hash == "coverage")
            let ranked = try [original, corrected].sorted {
                try StableContentHasher.sha256Hex(of: $0) < StableContentHasher.sha256Hex(of: $1)
            }
            let lower = try #require(ranked.first)
            let higher = try #require(ranked.last)
            let equalTime = later.addingTimeInterval(60.0000004)
            _ = try await service.persist([lower], on: db, seenAt: equalTime)
            #expect(try await service.persist([higher], on: db, seenAt: equalTime).updated == 1)
            #expect(try await service.persist([lower], on: db, seenAt: equalTime).ignored == 1)
            let winner = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            let expectedFingerprint = try StableContentHasher.sha256Hex(of: higher)
            #expect(winner.contentFingerprint == expectedFingerprint)
            let storedTime = winner.lastSeen
            #expect(abs(storedTime.timeIntervalSince(equalTime)) < 0.000001)
            // Reverse writer order at another sub-microsecond observation time.
            let reverseTime = equalTime.addingTimeInterval(60)
            _ = try await service.persist([higher], on: db, seenAt: reverseTime)
            #expect(try await service.persist([lower], on: db, seenAt: reverseTime).ignored == 1)
            let reverseWinner = try #require(try await SPCMesoModel.find(row.requireID(), on: db))
            #expect(reverseWinner.contentFingerprint == expectedFingerprint)
        }
    }

    @Test func roundTripAndCoverage() async throws {
        try await withDatabase { db, _ in
            let payload = try product()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let meso = SPCMesoModel(product: payload, contentFingerprint: "content", seenAt: now)
            try await meso.create(on: db)
            let id = try meso.requireID()
            let geometry = GeoShape.polygon(rings: [payload.coordinates.map { .init(lon: $0.longitude, lat: $0.latitude) }])
            let location = SPCMesoGeolocationModel(mesoID: id, geometry: geometry, geometryHash: "geometry")
            try await location.create(on: db)
            let stored = try #require(try await SPCMesoModel.query(on: db).filter(\.$id == id).with(\.$geolocation).first())
            #expect(stored.productKey == payload.productID)
            #expect(stored.issueYear == payload.issueYear)
            #expect(stored.number == payload.number)
            #expect(stored.issued == payload.issued)
            #expect(stored.validStart == payload.validStart)
            #expect(stored.validEnd == payload.validEnd)
            #expect(stored.title == payload.title)
            #expect(stored.sourceURL == payload.sourceURL.absoluteString)
            #expect(stored.areasAffected == payload.areasAffected)
            #expect(stored.summary == payload.summary)
            #expect(stored.concerning == payload.concerning)
            #expect(stored.watchProbability == payload.watchProbability)
            #expect(stored.watchProbabilityText == payload.watchProbabilityText)
            #expect(stored.peakWindMPH == payload.threats?.peakWindMPH)
            #expect(stored.hailRangeInches == payload.threats?.hailRangeInches)
            #expect(stored.tornadoStrength == payload.threats?.tornadoStrength)
            #expect(stored.contentFingerprint == "content")
            #expect(stored.firstSeen == now)
            #expect(stored.lastSeen == now)
            let geo = try #require(stored.geolocation)
            #expect(geo.geometry == geometry)
            #expect(geo.geometryHash == "geometry")
            #expect(geo.h3Cells.isEmpty)
            #expect(geo.h3Resolution == nil)
            #expect(geo.h3Hash == nil)
            geo.h3Cells = [Int64(0x8826c1a805fffff)]
            geo.h3Resolution = 8
            geo.h3Hash = "coverage"
            try await geo.update(on: db)
            let covered = try #require(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db))
            #expect(covered.h3Cells == geo.h3Cells)
            #expect(covered.h3Resolution == 8)
            #expect(covered.h3Hash == "coverage")
            try await meso.delete(on: db)
            #expect(try await SPCMesoGeolocationModel.find(geo.requireID(), on: db) == nil)
        }
    }

    @Test func databaseFailureRollsBackEntireFeed() async throws {
        let app = try await Application.make(.testing)
        let constraint = "meso_test_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let rejectedTitle = constraint
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            let sql = try #require(app.db as? any SQLDatabase)
            let xml = String(decoding: try feed(), as: UTF8.self)
            let first = try #require(SPCMesoParser.parse(Data(xml
                .replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Sat Dec 31 1800").utf8)).first)
            let secondXML = xml
                .replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Sun Dec 31 1801")
                .replacingOccurrences(of: "SPC MD 0123", with: "SPC MD " + rejectedTitle)
            let second = try #require(SPCMesoParser.parse(Data(secondXML.utf8)).first)
            let keys = [first.productID, second.productID]
            #expect(try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ keys).count() == 0)
            try await sql.raw("ALTER TABLE spc_mesos ADD CONSTRAINT \(ident: constraint) CHECK (title <> \(literal: second.title)) NOT VALID").run()
            do {
                var rejected = false
                do { _ = try await SPCMesoIngestPersistence().persist([first, second], on: app.db, seenAt: first.validStart) }
                catch { rejected = true }
                #expect(rejected)
                #expect(try await SPCMesoModel.query(on: app.db).filter(\.$productKey ~~ keys).count() == 0)
            } catch {
                try await sql.raw("ALTER TABLE spc_mesos DROP CONSTRAINT \(ident: constraint)").run()
                throw error
            }
            try await sql.raw("ALTER TABLE spc_mesos DROP CONSTRAINT \(ident: constraint)").run()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test func concurrentReplaysUseOneCanonicalSnapshot() async throws {
        let app = try await Application.make(.testing)
        let contenderApp = try await Application.make(.testing)
        var productKey: String?
        do {
            try await configure(app, mode: .api)
            try await configure(contenderApp, mode: .api)
            try await app.autoMigrate()
            let xml = String(decoding: try feed(), as: UTF8.self)
                .replacingOccurrences(of: "0550 PM CST Wed Dec 31 2025", with: "0550 PM CST Fri Dec 31 1802")
            let payload = try #require(SPCMesoParser.parse(Data(xml.utf8)).first)
            productKey = payload.productID
            #expect(try await SPCMesoModel.query(on: app.db).filter(\.$productKey == payload.productID).count() == 0)
            let service = SPCMesoIngestPersistence()
            let later = payload.validStart.addingTimeInterval(60)
            let database = app.db
            let contenderDatabase = contenderApp.db
            // Hold the first connection's lock until pg_locks proves the second
            // transaction is waiting on a different physical connection.
            let (first, secondTask) = try await database.transaction { db in
                let sql = try #require(db as? any SQLDatabase)
                try await sql.raw("LOCK TABLE spc_mesos IN SHARE ROW EXCLUSIVE MODE").run()
                let second = Task { try await service.persist([payload], on: contenderDatabase, seenAt: later) }
                struct Contention: Decodable { let blocked: Bool }
                var blocked = false
                for _ in 0..<100 {
                    let state = try #require(try await sql.raw("""
                        SELECT EXISTS (
                            SELECT 1 FROM pg_locks WHERE relation = 'spc_mesos'::regclass
                            AND mode = 'ShareRowExclusiveLock' AND NOT granted
                            AND pid <> pg_backend_pid()
                        ) AS blocked
                        """).first(decoding: Contention.self))
                    if state.blocked { blocked = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(blocked, "Second persistence transaction must contend on an independent connection")
                let first = try await service.persist([payload], on: db, seenAt: payload.validStart)
                return (first, second)
            }
            let results = [first, try await secondTask.value]
            #expect(results.reduce(0) { $0 + $1.inserted } == 1)
            #expect(results.reduce(0) { $0 + $1.unchanged } == 1)
            let rows = try await SPCMesoModel.query(on: app.db).filter(\.$productKey == payload.productID).all()
            #expect(rows.count == 1)
            let row = try #require(rows.first)
            #expect(row.lastSeen == later)
            let expectedFingerprint = try StableContentHasher.sha256Hex(of: payload)
            #expect(row.contentFingerprint == expectedFingerprint)
            #expect(try await SPCMesoGeolocationModel.query(on: app.db).filter(\.$meso.$id == row.requireID()).count() == 1)
            try await row.delete(on: app.db)
            productKey = nil
        } catch {
            if let productKey { try? await SPCMesoModel.query(on: app.db).filter(\.$productKey == productKey).delete() }
            try? await contenderApp.asyncShutdown()
            try? await app.asyncShutdown()
            throw error
        }
        try await contenderApp.asyncShutdown()
        try await app.asyncShutdown()
    }

    @Test func identitiesAndForeignKeys() async throws {
        try await withDatabase { db, sql in
            let first = SPCMesoModel(product: try product(), contentFingerprint: "a", seenAt: .now)
            try await first.create(on: db)
            let nextYear = SPCMesoModel(product: try product(year: 2026), contentFingerprint: "b", seenAt: .now)
            try await nextYear.create(on: db)
            #expect(first.number == nextYear.number)
            #expect(first.productKey != nextYear.productKey)
            try await expectRejected(on: sql) {
                let duplicate = SPCMesoModel(product: try product(), contentFingerprint: "c", seenAt: .now)
                duplicate.number = 999
                try await duplicate.create(on: db)
            }
            try await expectRejected(on: sql) {
                let duplicate = SPCMesoModel(product: try product(), contentFingerprint: "c", seenAt: .now)
                duplicate.productKey = "different-key"
                try await duplicate.create(on: db)
            }
            let geometry = GeoShape.polygon(rings: [])
            let location = SPCMesoGeolocationModel(mesoID: try first.requireID(), geometry: geometry, geometryHash: "g")
            try await location.create(on: db)
            try await expectRejected(on: sql) {
                try await SPCMesoGeolocationModel(mesoID: first.requireID(), geometry: geometry, geometryHash: "g").create(on: db)
            }
            try await expectRejected(on: sql) {
                try await SPCMesoGeolocationModel(mesoID: UUID(), geometry: geometry, geometryHash: "g").create(on: db)
            }
        }
    }

    @Test(arguments: ["Unlikely", "Unknown"])
    func nonNumericProbability(_ text: String) async throws {
        try await withDatabase { db, _ in
            let meso = SPCMesoModel(product: try product(watchText: text), contentFingerprint: "c", seenAt: .now)
            meso.concerning = nil
            meso.peakWindMPH = nil
            meso.hailRangeInches = nil
            meso.tornadoStrength = nil
            try await meso.create(on: db)
            let stored = try #require(try await SPCMesoModel.find(meso.requireID(), on: db))
            #expect(stored.watchProbability == nil)
            #expect(stored.watchProbabilityText == text)
            #expect(stored.concerning == nil)
            #expect(stored.peakWindMPH == nil)
            #expect(stored.hailRangeInches == nil)
            #expect(stored.tornadoStrength == nil)
        }
    }

    @Test func migrationReversal() async throws {
        try await withDatabase { db, sql in
            let migration = CreateSPCMesos()
            try await migration.revert(on: db)
            struct Tables: Decodable { let missing: Bool }
            let result = try #require(try await sql.raw("""
                SELECT to_regclass('spc_mesos') IS NULL
                    AND to_regclass('spc_meso_geolocation') IS NULL AS missing
                """).first(decoding: Tables.self))
            #expect(result.missing)
            try await migration.prepare(on: db)
            try await SPCMesoModel(product: product(), contentFingerprint: "c", seenAt: .now).create(on: db)
        }
    }
}
