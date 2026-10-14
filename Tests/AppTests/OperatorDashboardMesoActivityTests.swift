@testable import App
import ArcusCore
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Operator dashboard meso activity", .serialized, .sharedDatabase)
struct OperatorDashboardMesoActivityTests {
    private let now = Date(timeIntervalSince1970: 1_776_000_000)

    private func entry(number: Int = 42) -> StoredMesoActivityEntry {
        .init(productKey: "2026-MD\(number)", number: number, issued: now,
              validStart: now, validEnd: now.addingTimeInterval(3_600),
              areasAffected: "Colorado & <Kansas>", summary: "Canonical <script> & discussion\nNext line",
              concerning: "Watch 'likely'", watchProbability: 80, watchProbabilityText: "80 percent",
              peakWindMPH: 70, hailRangeInches: 1.75, tornadoStrength: "EF2+",
              sourceURL: "https://www.spc.noaa.gov/products/md/md0042.html?a=1&b=2",
              geometryAvailable: true, h3CoverageComplete: true)
    }

    @Test("Meso validity boundaries and sparse fields") func validityBoundariesAndSparseFields() {
        var e = entry()
        #expect(e.status(asOf: now.addingTimeInterval(-1)) == "Pending")
        #expect(e.status(asOf: now) == "Active")
        #expect(e.status(asOf: e.validEnd) == "Expired")
        e.watchProbability = nil; e.watchProbabilityText = ""
        e.concerning = nil; e.peakWindMPH = nil; e.hailRangeInches = nil; e.tornadoStrength = nil
        e.geometryAvailable = false; e.h3CoverageComplete = false
        e.sourceURL = "javascript:alert(1)"
        let html = OperatorDashboardPageRenderer.mesoActivity(.init(refreshedAt: now, capped: false, entries: [e]))
        #expect(html.contains("Watch probability: Unknown"))
        #expect(html.contains("No geometry"))
        #expect(!html.contains("Peak wind"))
        #expect(!html.contains("Tornado"))
        #expect(!html.contains("href="))
        #expect(html.contains("&lt;script&gt; &amp; discussion"))
    }

    @Test("Meso legacy snapshots and rendering states") func legacyDecodeAndRenderingStates() throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(OperatorDashboardStoredSnapshot.empty(now: now))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "mesoActivity")
        object["schemaVersion"] = 9
        let legacy = try JSONDecoder().decode(OperatorDashboardStoredSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.mesoActivity == nil)
        #expect(OperatorDashboardPageRenderer.mesoActivity(legacy.mesoActivity).contains("unavailable"))
        #expect(OperatorDashboardPageRenderer.mesoActivity(.init(refreshedAt: now, capped: false, entries: [])).contains("No active or recently issued"))
        let activity = StoredMesoActivity(refreshedAt: now, capped: true, entries: [entry()])
        let html = OperatorDashboardPageRenderer.mesoActivity(activity)
        #expect(html.contains("Capped sample: up to 50"))
        #expect(html.contains("MD 42 · Active"))
        #expect(html.contains("Watch probability: 80%"))
        #expect(html.contains("1.75 inches"))
        #expect(html.contains("a=1&amp;b=2"))
        #expect(html.contains("Colorado &amp; &lt;Kansas&gt;"))
        #expect(!html.contains("CAP"))

        // Optional inspectable fixture for executing the actual browser functions in Node.
        if let path = ProcessInfo.processInfo.environment["MESO_RENDER_EVIDENCE"] {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            var snapshot = OperatorDashboardStoredSnapshot.empty(now: now)
            snapshot.mesoActivity = activity
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)
            let json = JSONEncoder(); json.dateEncodingStrategy = .iso8601
            var expired = entry(); expired.validEnd = now
            var pending = entry(); pending.validStart = now.addingTimeInterval(1)
            var sparse = entry(); sparse.watchProbability = nil; sparse.watchProbabilityText = "Source unknown"
            sparse.concerning = nil; sparse.peakWindMPH = nil; sparse.hailRangeInches = nil; sparse.tornadoStrength = nil
            sparse.geometryAvailable = false; sparse.h3CoverageComplete = false; sparse.sourceURL = "javascript:alert(1)"
            let cases: [StoredMesoActivity?] = [activity, nil, .init(refreshedAt: now, capped: false, entries: []),
                .init(refreshedAt: now, capped: false, entries: [expired, pending, sparse])]
            try json.encode(cases.map { RenderCase(activity: $0, html: OperatorDashboardPageRenderer.mesoActivity($0)) })
                .write(to: URL(fileURLWithPath: path + "/render-cases.json"))
            try json.encode(response).write(to: URL(fileURLWithPath: path + "/snapshot.json"))
            try html.write(toFile: path + "/activity.html", atomically: true, encoding: .utf8)
            try OperatorDashboardPageRenderer.mesoSummary(response.redLights.spcMesoIngest).write(toFile: path + "/summary.html", atomically: true, encoding: .utf8)
            try OperatorDashboardPageRenderer.render(snapshot: response, page: .mesos, buildInfo: .init(version: "test", revision: nil)).write(toFile: path + "/page.html", atomically: true, encoding: .utf8)
        }
    }

    private struct SnapshotStore: OperatorDashboardSnapshotStore {
        var snapshot: OperatorDashboardStoredSnapshot?
        func load(on database: any Database) async throws -> OperatorDashboardStoredSnapshot? { snapshot }
        func save(_ snapshot: OperatorDashboardStoredSnapshot, on database: any Database) async throws {}
    }

    @Test("Meso route metrics and warning destinations") func mesoRouteMetricsAndWarningDestination() async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            var snapshot = OperatorDashboardStoredSnapshot.empty(now: now)
            snapshot.mesoActivity = .init(refreshedAt: now, capped: false, entries: [entry()])
            snapshot.fastRefreshedAt = now
            snapshot.spcMesoIngest.lastAttemptAt = now.addingTimeInterval(-3_600)
            app.operatorDashboardSnapshotStore = SnapshotStore(snapshot: snapshot)
            try await app.testing().test(.GET, "/dashboard/mesos", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("href=\"/dashboard/mesos\" aria-current=\"page\""))
                #expect(res.body.string.contains("MD 42 · Active"))
                #expect(res.body.string.contains("Snapshot is stale"))
                #expect(res.body.string.contains("updateSlot('meso-activity'"))
            })
            try await app.testing().test(.GET, "/v1/metrics", afterResponse: { res async throws in
                let payload = try res.content.decode(OperatorDashboardSnapshotResponse.self)
                #expect(payload.mesoActivity?.entries.first?.number == 42)
            })
            let health = OperatorDashboardPageRenderer.healthOverview(.init(snapshot: snapshot, renderedAt: now))
            #expect(health.contains("href=\"/dashboard/mesos\">Inspect Meso Activity"))
            snapshot.stuckClaimedRows.count = 1
            let deliveryHealth = OperatorDashboardPageRenderer.healthOverview(.init(snapshot: snapshot, renderedAt: now))
            #expect(deliveryHealth.contains("href=\"/dashboard/delivery\">Inspect Delivery"))
            #expect(deliveryHealth.contains("href=\"/dashboard/mesos\">Inspect Meso Activity"))
            app.operatorDashboardSnapshotStore = SnapshotStore(snapshot: nil)
            try await app.testing().test(.GET, "/dashboard/mesos", afterResponse: { res async in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains("Dashboard Snapshot Unavailable"))
                #expect(res.body.string.contains("/dashboard/mesos"))
            })
        } catch { try? await app.asyncShutdown(); throw error }
        try await app.asyncShutdown()
    }

    @Test("Meso canonical projection window ordering and cap") func canonicalProjectionWindowOrderingAndCap() async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                // A transaction keeps this deterministic and rolls fixture data back on success or failure.
                try await app.db.transaction { db in
                    let dbSQL = try #require(db as? any SQLDatabase)
                    try await dbSQL.raw("DELETE FROM spc_mesos").run()
                    for n in 1...54 {
                        let issued = n <= 3 ? now.addingTimeInterval(-49 * 3_600) : (n == 4 ? now.addingTimeInterval(-48 * 3_600) : now)
                        let start = n == 1 || n >= 5 ? now.addingTimeInterval(-100) : issued
                        let end = n == 1 || n == 5 ? now.addingTimeInterval(100) : (n == 2 || n >= 5 ? now : issued.addingTimeInterval(100))
                        let product = MesoscaleDiscussionPayload(number: n, title: "MD \(n)",
                            sourceURL: URL(string: "https://www.spc.noaa.gov/products/md/md\(n).html")!,
                            issued: issued, validStart: start, validEnd: end, areasAffected: "Test",
                            summary: "Discussion", concerning: nil, watchProbability: nil,
                            watchProbabilityText: "Unknown", threats: nil, coordinates: [])
                        try await SPCMesoModel(product: product, contentFingerprint: "test", seenAt: now).create(on: db)
                        if n == 4 {
                            try await dbSQL.raw("""
                                INSERT INTO spc_meso_geolocation (id, meso_id, geometry, geometry_hash, h3_cells, h3_resolution, h3_hash)
                                SELECT \(bind: UUID()), id, '{}'::jsonb, 'test', '{}'::bigint[], 8, 'complete'
                                FROM spc_mesos WHERE md_number = 4
                                """).run()
                            let covered = try await OperatorDashboardSnapshotRefresher().loadMesoActivity(on: dbSQL, now: now)
                            #expect(covered.entries.first?.geometryAvailable == true)
                            #expect(covered.entries.first?.h3CoverageComplete == true)
                        }
                        if n == 3 {
                            let uncapped = try await OperatorDashboardSnapshotRefresher().loadMesoActivity(on: dbSQL, now: now)
                            #expect(!uncapped.capped)
                            #expect(uncapped.entries.map(\.number) == [1]) // older active included; expired boundary excluded
                        }
                    }
                    let activity = try await OperatorDashboardSnapshotRefresher().loadMesoActivity(on: dbSQL, now: now)
                    #expect(activity.capped)
                    #expect(activity.entries.count == 50)
                    let expected = try await dbSQL.raw("SELECT product_key AS key FROM spc_mesos WHERE issued >= \(bind: now) ORDER BY product_key ASC LIMIT 49").all(decoding: ProductKeyRow.self)
                    #expect(activity.entries.dropLast().map(\.productKey) == expected.map(\.key))
                    #expect(activity.entries.last?.number == 1) // active product survives the history cap
                    #expect(activity.entries.filter { $0.number != 4 }.allSatisfy { !$0.geometryAvailable && !$0.h3CoverageComplete })
                    throw FixtureRollback.done
                }
            } catch FixtureRollback.done { } catch { try? await app.asyncShutdown(); throw error }
            try await app.asyncShutdown()
        }
    }

    private struct RenderCase: Encodable { let activity: StoredMesoActivity?; let html: String }
    private struct ProductKeyRow: Decodable { let key: String }
    private enum FixtureRollback: Error { case done }
}
