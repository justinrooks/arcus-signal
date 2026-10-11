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
