@testable import App
import ArcusCore
import Fluent
import FluentSQL
import Queues
import Testing
import Vapor
import VaporTesting
import XCTQueues

@Suite("V3 consent authority", .serialized, .sharedDatabase)
struct DeviceV3ControllerTests {
    private let credential = Data(repeating: 0xfb, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let name = Environment.get("DATABASE_URL").flatMap(URL.init(string:))?.lastPathComponent ?? ""
        guard name.range(of: #"^arcus_issue[0-9]+_(test|validation)_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else {
            throw Abort(.internalServerError, reason: "An explicitly issue-scoped isolated test database is required")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            app.queues.use(.test)
            _ = try await app.testing().sendRequest(.GET, "health")
            try await test(app)
            try await cleanup(app)
            try await app.asyncShutdown()
        } catch {
            try? await cleanup(app)
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func cleanup(_ app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        for table in ["installation_activity_daily", "installation_credentials", "device_installations"] {
            try await sql.raw("DELETE FROM \(unsafeRaw: table) WHERE installation_id::text LIKE '03890000-%'").run()
        }
    }

    private func id() -> UUID { UUID(uuidString: "03890000-" + UUID().uuidString.dropFirst(9))! }
    private func post(_ path: String, _ body: [String: Any], app: Application, authorized: Bool = true) async throws -> TestingHTTPResponse {
        try await postData(path, data: JSONSerialization.data(withJSONObject: body), app: app, authorized: authorized)
    }
    private func postData(_ path: String, data: Data, app: Application, authorized: Bool = true) async throws -> TestingHTTPResponse {
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        if authorized { headers.bearerAuthorization = .init(token: credential) }
        return try await app.testing().sendRequest(.POST, path, headers: headers,
            body: .init(data: data))
    }
    private func enroll(_ id: UUID, app: Application) async throws {
        #expect(try await post("v2/devices/enroll", ["installationId": id.uuidString, "credential": credential], app: app).status == .ok)
    }
    private func preferences(_ id: UUID, _ revision: Int64 = 1, sharing: Bool = true, subscribed: Bool = true) -> [String: Any] {
        ["installationId": id.uuidString, "consentRevision": revision,
         "consent": ["isSubscribed": subscribed, "mesoNotificationsEnabled": true,
                     "locationSharingEnabled": sharing, "locationAuthorization": "always"],
         "apnsEnvironment": "sandbox", "platform": "iOS", "osVersion": "26", "appVersion": "1", "buildNumber": "1"]
    }
    private func location(_ id: UUID, capturedAt: Date = .now, county: String = "COC031") -> [String: Any] {
        ["installationId": id.uuidString, "capturedAt": ISO8601DateFormatter().string(from: capturedAt),
         "locationAgeSeconds": 0, "horizontalAccuracyMeters": 10, "cellScheme": "ugc-only", "county": county, "source": "foregroundPrime"]
    }
    private func status(_ response: TestingHTTPResponse) throws -> String {
        let object = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? [String: Any])
        return try #require(object["status"] as? String)
    }
    private func snapshot(_ id: UUID, app: Application) async throws -> [String] {
        let sql = try #require(app.db as? any SQLDatabase)
        var result: [String] = []
        for table in ["device_installations", "device_presence", "installation_activity_daily", "presence_reconciliation_outbox"] {
            let row = try await sql.raw("SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text AS value FROM \(unsafeRaw: table) t WHERE installation_id = \(bind: id)").first()
            result.append(try row?.decode(column: "value", as: String?.self) ?? "null")
        }
        return result
    }

    @Test("Tokenless initialization, monotonic consent, same-revision binding, stale no-effects, and re-enable")
    func acceptance() async throws {
        try await withApp { app in
            app.mesoNotificationsEnabled = true
            let id = id()
            try await enroll(id, app: app)
            for root in ["", "api/"] {
                #expect(try await post("\(root)v3/devices/location-snapshots", location(id), app: app).status == .conflict)
                #expect(try await post("\(root)v3/devices/foreground-activity", ["installationId": id.uuidString], app: app).status == .conflict)
            }
            let first = try await post("v3/devices/preferences", preferences(id), app: app)
            #expect(try status(first) == "accepted")
            let response = try first.content.decode(DevicePreferencesV3AcceptedResponse.self)
            #expect(response.acceptedConsentRevision == 1)
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "")
            var binding = preferences(id)
            binding["apnsDeviceToken"] = "rotated-token"
            binding["apnsEnvironment"] = "prod"
            #expect(try status(try await post("api/v3/devices/preferences", binding, app: app)) == "unchanged")
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "rotated-token")
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsEnvironmentRaw == "prod")
            var omitted = preferences(id)
            for nullToken in [false, true] {
                if nullToken { omitted["apnsDeviceToken"] = NSNull() }
                #expect(try status(try await post("v3/devices/preferences", omitted, app: app)) == "unchanged")
                #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsEnvironmentRaw == "prod")
                #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "rotated-token")
            }
            #expect(try status(try await post("v3/devices/preferences", preferences(id, 2, sharing: false), app: app)) == "accepted")
            let before = try await snapshot(id, app: app)
            let stale = try await post("v3/devices/preferences", binding, app: app)
            #expect(try status(stale) == "stale")
            let staleResponse = try stale.content.decode(DevicePreferencesV3AcceptedResponse.self)
            #expect(staleResponse.acceptedConsentRevision == 2 && !staleResponse.serverOwnsMesoNotificationDelivery)
            #expect(try await post("v3/devices/preferences", preferences(id, 2), app: app).status == .conflict)
            #expect(try status(try await post("v3/devices/location-snapshots", location(id), app: app)) == "ignored")
            #expect(try await snapshot(id, app: app) == before)
            #expect(try status(try await post("v3/devices/preferences", preferences(id, 3), app: app)) == "accepted")
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "rotated-token")
        }
    }

    @Test("Presence-only ordering, equal-time merge, sharing and authorization gates, and activity")
    func presence() async throws {
        try await withApp { app in
            let id = id(), now = Date().addingTimeInterval(-10)
            try await enroll(id, app: app)
            var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
            _ = try await post("v3/devices/preferences", prefs, app: app)
            let installationBefore = try await snapshot(id, app: app)[0]
            var body = location(id, capturedAt: now)
            // Unknown legacy fields cannot become another consent/binding writer.
            body["isSubscribed"] = false; body["apnsDeviceToken"] = "wrong"; body["auth"] = "denied"
            #expect(try status(try await post("api/v3/devices/location-snapshots", body, app: app)) == "accepted")
            #expect(try status(try await post("v3/devices/location-snapshots", location(id, capturedAt: now, county: "COC013"), app: app)) == "accepted")
            let before = try await snapshot(id, app: app)
            #expect(try status(try await post("v3/devices/location-snapshots", location(id, capturedAt: now.addingTimeInterval(-1)), app: app)) == "stale")
            #expect(try await snapshot(id, app: app) == before)
            #expect(before[0] == installationBefore)
            #expect(try await DevicePresenceModel.find(id, on: app.db)?.county == "COC013")
            #expect(!app.queues.test.all(ReconcileInstallationAlertsJob.self).isEmpty)
            for root in ["", "api/"] {
                #expect(try await post("\(root)v3/devices/foreground-activity", ["installationId": id.uuidString], app: app).status == .noContent)
            }
            #expect(try await snapshot(id, app: app)[0...1] == before[0...1])
            var denied = preferences(id, 2)
            denied["consent"] = ["isSubscribed": true, "mesoNotificationsEnabled": true, "locationSharingEnabled": true, "locationAuthorization": "denied"]
            _ = try await post("v3/devices/preferences", denied, app: app)
            let deniedBefore = try await snapshot(id, app: app)
            #expect(try status(try await post("v3/devices/location-snapshots", location(id), app: app)) == "ignored")
            #expect(try await snapshot(id, app: app) == deniedBefore)
        }
    }

    @Test("Accepted sharing gates candidates, reconciliation, and a candidate held across revocation")
    func eligibility() async throws {
        try await withApp { app in
            let id = id(); try await enroll(id, app: app)
            var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
            _ = try await post("v3/devices/preferences", prefs, app: app)
            var presence = location(id)
            presence["cellScheme"] = "h3"; presence["h3Cell"] = Int64(614934489169608703); presence["h3Resolution"] = 8
            _ = try await post("v3/devices/location-snapshots", presence, app: app)
            let store = NotificationCandidateStore()
            let candidates = try await store.loadUGCCandidates(ugcCodes: ["COC031"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db)
            let candidate = try #require(candidates.first)
            #expect(try await store.acceptedConsentAllowsDelivery(candidate, meso: true, on: app.db))
            _ = try await post("v3/devices/preferences", preferences(id, 2, sharing: false), app: app)
            #expect(try await store.loadUGCCandidates(ugcCodes: ["COC031"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).isEmpty)
            #expect(try await store.loadH3Candidates(cells: [614934489169608703], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).isEmpty)
            #expect(try await !store.acceptedConsentAllowsDelivery(candidate, on: app.db))
            #expect(try await !store.acceptedConsentAllowsDelivery(candidate, meso: true, on: app.db))
            let state = try #require(PresenceReconciliationState(installation: try await DeviceInstallationModel.find(id, on: app.db), presence: try await DevicePresenceModel.find(id, on: app.db)))
            #expect(!PresenceReconciliationTrigger.isUsable(state, now: .now))
        }
    }

    @Test("Every alias authenticates and every legacy mutation is fenced after promotion")
    func routeMatrix() async throws {
        try await withApp { app in
            let id = id(); try await enroll(id, app: app)
            _ = try await post("v3/devices/preferences", preferences(id), app: app)
            let before = try await snapshot(id, app: app)
            for root in ["", "api/"] {
                for endpoint in ["preferences", "location-snapshots", "foreground-activity"] {
                    let body = endpoint == "preferences" ? preferences(id) : endpoint == "location-snapshots" ? location(id) : ["installationId": id.uuidString]
                    #expect(try await post("\(root)v3/devices/\(endpoint)", body, app: app, authorized: false).status == .unauthorized)
                    var legacy = location(id)
                    legacy.merge(["apnsDeviceToken": "legacy", "apnsEnvironment": "sandbox", "platform": "iOS", "osVersion": "26", "appVersion": "1", "buildNumber": "1", "auth": "always", "isSubscribed": true, "source": "foregroundPrime", "reason": "preferenceChanged"]) { _, new in new }
                    #expect(try await post("\(root)v2/devices/\(endpoint)", legacy, app: app).status == .conflict)
                    #expect(try await post("\(root)v1/devices/\(endpoint)", legacy, app: app).status == .unauthorized)
                }
            }
            try await enroll(id, app: app)
            #expect(try await snapshot(id, app: app) == before)
            for revision in [0, -1] {
                #expect(try await post("v3/devices/preferences", preferences(id, Int64(revision)), app: app).status == .badRequest)
            }
            var invalid = preferences(id); invalid["apnsDeviceToken"] = "  "
            #expect(try await post("v3/devices/preferences", invalid, app: app).status == .badRequest)
        }
    }

    @Test("Actual route writes serialize across PostgreSQL sessions in both commit orders")
    func races() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            for kind in ["preferences", "location-snapshots", "legacy"] {
                for revokeFirst in [false, true] {
                    let id = id(); try await enroll(id, app: app)
                    if kind != "legacy" {
                        _ = try await post("v3/devices/preferences", preferences(id), app: app)
                        _ = try await post("v3/devices/location-snapshots", location(id), app: app)
                    }
                    let before = try await snapshot(id, app: app)
                    // A test-only trigger pauses the REAL first route after it holds the production
                    // installation lock and has written, but before commit. No production test hooks.
                    try await sql.raw("""
                        CREATE FUNCTION issue389_pause() RETURNS trigger LANGUAGE plpgsql AS $$
                        BEGIN PERFORM pg_advisory_xact_lock(389, 1); RETURN NEW; END $$
                        """).run()
                    for table in ["device_installations", "device_presence"] {
                        try await sql.raw("""
                            CREATE TRIGGER issue389_pause AFTER INSERT OR UPDATE ON \(unsafeRaw: table)
                            FOR EACH ROW WHEN (NEW.installation_id = '\(unsafeRaw: id.uuidString)'::uuid)
                            EXECUTE FUNCTION issue389_pause()
                            """).run()
                    }
                    let locked = V3TestEvent(), release = V3TestEvent()
                    let blocker = Task {
                        try await app.db.transaction { database in
                            let connection = try #require(database as? any SQLDatabase)
                            try await connection.raw("SELECT pg_advisory_xact_lock(389, 1)").run()
                            await locked.signal(); await release.wait()
                        }
                    }
                    await locked.wait()
                    let revokePath = "v3/devices/preferences"
                    let revokeBody = preferences(id, 3, sharing: false, subscribed: false)
                    let otherPath: String
                    let otherBody: [String: Any]
                    switch kind {
                    case "preferences": otherPath = revokePath; otherBody = preferences(id, 2)
                    case "location-snapshots": otherPath = "v3/devices/location-snapshots"; otherBody = location(id, county: "COC013")
                    default:
                        otherPath = "api/v2/devices/preferences"
                        otherBody = ["installationId": id.uuidString, "apnsDeviceToken": "legacy", "apnsEnvironment": "sandbox", "platform": "iOS", "osVersion": "26", "appVersion": "1", "buildNumber": "1", "auth": "always", "isSubscribed": true, "source": "foregroundPrime", "reason": "preferenceChanged"]
                    }
                    let revokeData = try JSONSerialization.data(withJSONObject: revokeBody)
                    let otherData = try JSONSerialization.data(withJSONObject: otherBody)
                    let first = Task { try await postData(revokeFirst ? revokePath : otherPath, data: revokeFirst ? revokeData : otherData, app: app) }
                    do {
                        try await waitForAdvisoryWaiters(1, sql: sql)
                        let second = Task { try await postData(revokeFirst ? otherPath : revokePath, data: revokeFirst ? otherData : revokeData, app: app) }
                        do {
                            try await waitForAdvisoryWaiters(2, sql: sql)
                            await release.signal()
                            try await blocker.value
                            let results = try await (first.value, second.value)
                            #expect(results.0.status == .ok)
                            #expect(results.1.status == (kind == "legacy" && revokeFirst ? .conflict : .ok))
                            let installation = try #require(try await DeviceInstallationModel.find(id, on: app.db))
                            #expect(installation.consentRevision == 3 && !installation.isSubscribed && !installation.locationSharingEnabled)
                            if revokeFirst && kind == "location-snapshots" {
                                #expect(try status(results.1) == "ignored")
                                #expect(try await snapshot(id, app: app)[1...] == before[1...])
                            }
                            if revokeFirst && kind == "preferences" { #expect(try status(results.1) == "stale") }
                        } catch {
                            await release.signal(); _ = try? await second.value; throw error
                        }
                    } catch {
                        await release.signal(); _ = try? await first.value; _ = try? await blocker.value
                        try? await dropPause(sql); throw error
                    }
                    try await dropPause(sql)
                }
            }
        }
    }

    private func waitForAdvisoryWaiters(_ count: Int, sql: any SQLDatabase) async throws {
        for _ in 0..<500 {
            let row = try await sql.raw("SELECT count(*)::int AS n FROM pg_stat_activity WHERE datname = current_database() AND wait_event = 'advisory'").first()
            if try row?.decode(column: "n", as: Int.self) ?? 0 >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Abort(.internalServerError, reason: "Expected PostgreSQL advisory-lock wait was not observed")
    }
    private func dropPause(_ sql: any SQLDatabase) async throws {
        for table in ["device_installations", "device_presence"] {
            try await sql.raw("DROP TRIGGER IF EXISTS issue389_pause ON \(unsafeRaw: table)").run()
        }
        try await sql.raw("DROP FUNCTION IF EXISTS issue389_pause()").run()
    }

    @Test("Migration preserves legacy rows, permits pre-rollout rollback, and refuses erasing a v3 fence")
    func migration() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            let id = id()
            try await AddDeviceConsentRevision().revert(on: app.db)
            try await sql.raw("""
                INSERT INTO device_installations (installation_id, apns_device_token, apns_environment, platform, os_version, app_version, build_number, location_auth, is_active, is_subscribed, last_seen_at)
                VALUES (\(bind: id), 'legacy', 'sandbox', 'iOS', '26', '1', '1', 'always', TRUE, TRUE, NOW())
                """).run()
            try await AddDeviceConsentRevision().prepare(on: app.db)
            let installation = try #require(try await DeviceInstallationModel.find(id, on: app.db))
            #expect(installation.locationSharingEnabled && installation.consentRevision == nil)
            try await enroll(id, app: app)
            _ = try await post("v3/devices/preferences", preferences(id), app: app)
            await #expect(throws: (any Error).self) { try await AddDeviceConsentRevision().revert(on: app.db) }
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.consentRevision == 1)
        }
    }
}

private actor V3TestEvent {
    private var ready = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if ready { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        ready = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
