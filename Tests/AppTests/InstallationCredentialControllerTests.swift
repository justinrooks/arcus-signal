@testable import App
import ArcusCore
import Fluent
import FluentSQL
import Queues
import Testing
import Vapor
import VaporTesting
import XCTQueues

@Suite("Installation credential authority", .serialized, .sharedDatabase)
struct InstallationCredentialControllerTests {
    private let owner = Data(repeating: 0xfb, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
    private let stranger = Data(repeating: 0xfc, count: 32).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let name = Environment.get("DATABASE_URL").flatMap(URL.init(string:))?.lastPathComponent ?? ""
        guard name.hasPrefix("arcus_issue386_test_") || name.hasPrefix("arcus_issue386_validation_") else {
            throw Abort(.internalServerError, reason: "An issue-386 isolated test database is required")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            app.queues.use(.test)
            try await test(app)
            try await cleanup(app)
            try await app.asyncShutdown()
        } catch {
            try? await cleanup(app)
            try? await app.asyncShutdown()
            throw error
        }
    }

    private func newID() -> UUID {
        let r = UUID().uuid
        return UUID(uuid: (0x03, 0x86, 0, 0, r.4, r.5, r.6, r.7, r.8, r.9, r.10, r.11, r.12, r.13, r.14, r.15))
    }

    private func cleanup(_ app: Application) async throws {
        let sql = try #require(app.db as? any SQLDatabase)
        // This suite owns only this UUID prefix, in an explicitly isolated database.
        try await sql.raw("DELETE FROM installation_activity_daily WHERE installation_id::text LIKE '03860000-%'").run()
        try await sql.raw("DELETE FROM installation_credentials WHERE installation_id::text LIKE '03860000-%'").run()
        try await sql.raw("DELETE FROM device_installations WHERE installation_id::text LIKE '03860000-%'").run()
    }

    private func post(_ path: String, body: [String: Any], credential: String? = nil,
                      app: Application) async throws -> TestingHTTPResponse {
        var headers: HTTPHeaders = ["Content-Type": "application/json"]
        if let credential { headers.bearerAuthorization = .init(token: credential) }
        return try await app.testing().sendRequest(.POST, path, headers: headers,
            body: .init(data: JSONSerialization.data(withJSONObject: body)))
    }

    private func enroll(_ id: UUID, credential: String, root: String = "", app: Application) async throws -> TestingHTTPResponse {
        try await post("\(root)v2/devices/enroll", body: ["installationId": id.uuidString, "credential": credential], app: app)
    }

    private func payload(_ id: UUID, endpoint: String, subscribed: Bool = true) -> [String: Any] {
        var body: [String: Any] = ["installationId": id.uuidString]
        guard endpoint != "foreground-activity" else { return body }
        body.merge(["apnsDeviceToken": "new-test-token", "apnsEnvironment": "sandbox", "platform": "iOS",
                    "osVersion": "26.0", "appVersion": "1.0", "buildNumber": "1", "auth": "always",
                    "isSubscribed": subscribed, "mesoNotificationsEnabled": true,
                    "source": "foregroundPrime", "reason": "preferenceChanged"]) { _, new in new }
        if endpoint == "location-snapshots" {
            body.merge(["capturedAt": ISO8601DateFormatter().string(from: .now), "locationAgeSeconds": 0,
                        "horizontalAccuracyMeters": 10, "cellScheme": CellScheme.ugcOnly.rawValue, "county": "COC031",
                        "zone": "COZ041", "fireZone": "COF241"]) { _, new in new }
        }
        return body
    }

    @Test("Enrollment is token-free, retryable across aliases, and stores only a verifier")
    func enrollmentContract() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            let first = try await enroll(id, credential: owner, app: app)
            #expect(first.status == .ok)
            #expect(try first.content.decode(InstallationEnrollmentAcceptedResponse.self) == .init(status: "accepted"))
            let retry = try await enroll(id, credential: owner + "=", root: "api/", app: app)
            #expect(retry.status == .ok)
            #expect(retry.body.string == first.body.string)
            #expect(try await enroll(id, credential: stranger, app: app).status == .conflict)
            let verifier = try await InstallationCredentialStore.load(id, on: app.db)
            #expect(verifier == InstallationCredentialStore.verifier(for: owner))
            #expect(verifier != owner)
            #expect(try await DeviceInstallationModel.find(id, on: app.db) == nil)
            #expect(try await DevicePresenceModel.find(id, on: app.db) == nil)
            #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count() == 0)
            #expect(!first.body.string.contains(owner))
            // A non-notification user can immediately report activity.
            #expect(try await post("v2/devices/foreground-activity", body: payload(id, endpoint: "foreground-activity"), credential: owner, app: app).status == .noContent)
        }
    }

    @Test("Malformed enrollment cannot leave authority behind")
    func malformedEnrollment() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            for secret in ["", "short", String(repeating: "a", count: 44), owner + "==", owner + "\n", String(repeating: "/", count: 43)] {
                #expect(try await enroll(id, credential: secret, app: app).status == .badRequest)
            }
            for body: [String: Any] in [["installationId": "bad", "credential": owner], ["installationId": id.uuidString], ["credential": owner]] {
                #expect(try await post("api/v2/devices/enroll", body: body, app: app).status == .badRequest)
            }
            #expect(try await InstallationCredentialStore.load(id, on: app.db) == nil)
        }
    }

    @Test("Enrollment persistence failure rolls back and a later retry can claim")
    func failedEnrollment() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("""
                ALTER TABLE installation_credentials ADD CONSTRAINT issue386_reject_claim
                CHECK (installation_id <> '\(unsafeRaw: id.uuidString)'::uuid) NOT VALID
                """).run()
            do {
                #expect(try await enroll(id, credential: owner, app: app).status == .internalServerError)
                #expect(try await InstallationCredentialStore.load(id, on: app.db) == nil)
                #expect(try await DeviceInstallationModel.find(id, on: app.db) == nil)
            } catch {
                try? await sql.raw("ALTER TABLE installation_credentials DROP CONSTRAINT issue386_reject_claim").run()
                throw error
            }
            try await sql.raw("ALTER TABLE installation_credentials DROP CONSTRAINT issue386_reject_claim").run()
            #expect(try await enroll(id, credential: owner, app: app).status == .ok)
        }
    }

    @Test("Credential migration is additive and reversible before rollout")
    func additiveMigration() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            #expect(try await post("v1/devices/preferences", body: payload(id, endpoint: "preferences"), app: app).status == .ok)
            let migration = CreateInstallationCredentials()
            try await migration.revert(on: app.db)
            try await migration.prepare(on: app.db)
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "new-test-token")
            #expect(try await enroll(id, credential: owner, app: app).status == .ok)
        }
    }

    @Test("Every mutation and alias rejects absent, malformed, wrong-owner, and v1 bypass proofs without effects")
    func protectedMutationMatrix() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID(), other = newID()
            #expect(try await enroll(id, credential: owner, app: app).status == .ok)
            #expect(try await enroll(other, credential: stranger, app: app).status == .ok)
            for root in ["", "api/"] {
                for endpoint in ["preferences", "location-snapshots", "foreground-activity"] {
                    let body = payload(id, endpoint: endpoint)
                    for proof in [nil, "malformed", stranger] {
                        #expect(try await post("\(root)v2/devices/\(endpoint)", body: body, credential: proof, app: app).status == .unauthorized)
                    }
                    for proof in [nil, owner, stranger] {
                        #expect(try await post("\(root)v1/devices/\(endpoint)", body: body, credential: proof, app: app).status == .unauthorized)
                    }
                }
            }
            #expect(try await DeviceInstallationModel.find(id, on: app.db) == nil)
            #expect(try await DevicePresenceModel.find(id, on: app.db) == nil)
            #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count() == 0)
            let sql = try #require(app.db as? any SQLDatabase)
            #expect(try await sql.raw("SELECT 1 FROM installation_activity_daily WHERE installation_id = \(bind: id)").first() == nil)
            let unclaimed = newID()
            for endpoint in ["preferences", "location-snapshots", "foreground-activity"] {
                #expect(try await post("v2/devices/\(endpoint)", body: payload(unclaimed, endpoint: endpoint), credential: owner, app: app).status == .unauthorized)
            }
        }
    }

    @Test("Owner v2 writes persist first presence, dispatch reconciliation, and record activity")
    func ownerWriteEffects() async throws {
        try await withApp { (app: Application) async throws in
            for root in ["", "api/"] {
                let id = newID()
                #expect(try await enroll(id, credential: owner, app: app).status == .ok)
                #expect(try await post("\(root)v2/devices/location-snapshots", body: payload(id, endpoint: "location-snapshots"), credential: owner, app: app).status == .ok)
                let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(presence.county == "COC031")
                #expect(presence.source == .foregroundPrime)
                let intent = try #require(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).first())
                #expect(intent.triggerCategory == .firstUsablePresence)
                #expect(intent.state == .done)
                #expect(intent.attemptCount == 1)
                let jobs = app.queues.test.all(ReconcileInstallationAlertsJob.self)
                #expect(jobs.contains { $0.installationId == id && $0.intentId == intent.id })
                #expect(try await post("\(root)v2/devices/foreground-activity", body: payload(id, endpoint: "foreground-activity"), credential: owner, app: app).status == .noContent)
                let sql = try #require(app.db as? any SQLDatabase)
                #expect(try await sql.raw("SELECT 1 FROM installation_activity_daily WHERE installation_id = \(bind: id)").first() != nil)
            }
        }
    }

    @Test("Attacker writes cannot overwrite populated claimed state or dispatch reconciliation")
    func populatedStateRejectsOverwrite() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            #expect(try await enroll(id, credential: owner, app: app).status == .ok)
            for endpoint in ["location-snapshots", "foreground-activity"] {
                _ = try await post("v2/devices/\(endpoint)", body: payload(id, endpoint: endpoint), credential: owner, app: app)
            }
            let sql = try #require(app.db as? any SQLDatabase)
            func snapshots() async throws -> [String] {
                var values: [String] = []
                for table in ["device_installations", "device_presence", "installation_activity_daily", "presence_reconciliation_outbox"] {
                    let row = try await sql.raw("""
                        SELECT jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text AS snapshot
                        FROM \(unsafeRaw: table) t WHERE installation_id = \(bind: id)
                        """).first()
                    values.append(try row?.decode(column: "snapshot", as: String?.self) ?? "null")
                }
                return values
            }
            let before = try await snapshots()
            #expect(before.allSatisfy { $0 != "null" })
            let dispatched = app.queues.test.all(ReconcileInstallationAlertsJob.self).count
            for root in ["", "api/"] {
                for version in ["v1", "v2"] {
                    for endpoint in ["preferences", "location-snapshots", "foreground-activity"] {
                        var attack = payload(id, endpoint: endpoint, subscribed: false)
                        if endpoint != "foreground-activity" {
                            attack["apnsDeviceToken"] = "attacker-token"
                            attack["mesoNotificationsEnabled"] = false
                            if endpoint == "location-snapshots" { attack["county"] = "COC013" }
                        }
                        for proof in [nil, stranger] {
                            #expect(try await post("\(root)\(version)/devices/\(endpoint)", body: attack, credential: proof, app: app).status == .unauthorized)
                        }
                    }
                }
            }
            #expect(try await snapshots() == before)
            #expect(app.queues.test.all(ReconcileInstallationAlertsJob.self).count == dispatched)
        }
    }

    @Test("Legacy claim preserves metadata and presence; owner mutations preserve APNs and consent behavior")
    func legacyClaimAndAuthorizedWrites() async throws {
        try await withApp { (app: Application) async throws in
            let id = newID()
            #expect(try await post("v1/devices/location-snapshots", body: payload(id, endpoint: "location-snapshots"), app: app).status == .ok)
            let before = try #require(try await DeviceInstallationModel.find(id, on: app.db))
            let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
            let intents = try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count()
            #expect(try await enroll(id, credential: owner, app: app).status == .ok)
            let after = try #require(try await DeviceInstallationModel.find(id, on: app.db))
            #expect(after.updatedAt == before.updatedAt)
            #expect(after.apnsDeviceToken == before.apnsDeviceToken)
            #expect(after.isSubscribed == before.isSubscribed)
            #expect(try await DevicePresenceModel.find(id, on: app.db)?.capturedAt == presence.capturedAt)
            #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count() == intents)
            for root in ["", "api/"] {
                for subscribed in [false, true] {
                    var body = payload(id, endpoint: "preferences", subscribed: subscribed)
                    body["apnsDeviceToken"] = "rotated-token"
                    #expect(try await post("\(root)v2/devices/preferences", body: body, credential: owner, app: app).status == .ok)
                    let updated = try #require(try await DeviceInstallationModel.find(id, on: app.db))
                    #expect(updated.isSubscribed == subscribed)
                    #expect(updated.apnsDeviceToken == "rotated-token")
                }
                for endpoint in ["location-snapshots", "foreground-activity"] {
                    #expect(try await post("\(root)v2/devices/\(endpoint)", body: payload(id, endpoint: endpoint), credential: owner, app: app).status == (endpoint == "foreground-activity" ? .noContent : .ok))
                }
            }
        }
    }

    @Test("Legacy compatibility switch rejects unclaimed writes and keeps enrollment available")
    func legacyBoundary() async throws {
        try await withApp { (app: Application) async throws in
            app.deviceLegacyWritesEnabled = false
            for root in ["", "api/"] {
                for endpoint in ["preferences", "location-snapshots", "foreground-activity"] {
                    #expect(try await post("\(root)v1/devices/\(endpoint)", body: payload(newID(), endpoint: endpoint), app: app).status == .unauthorized)
                }
            }
            #expect(try await enroll(newID(), credential: owner, app: app).status == .ok)
        }
    }

    @Test("Legacy writes cannot pass a concurrent claim or cross its commit boundary")
    func claimVersusLegacyWrite() async throws {
        try await withApp { (app: Application) async throws in
            _ = try await app.testing().sendRequest(.GET, "health")
            for claimFirst in [true, false] {
                let id = newID()
                let locked = CredentialTestEvent(), release = CredentialTestEvent()
                let holder = Task {
                    do {
                        try await app.db.transaction { database in
                            try await InstallationCredentialStore.lock(id, on: database)
                            if claimFirst {
                                try await InstallationCredentialStore.enroll(id,
                                    verifier: try #require(InstallationCredentialStore.verifier(for: owner)), on: database)
                            } else {
                                // Simulate a legacy mutation while holding the production authority lock.
                                try await InstallationActivityDailyStore().record(installationID: id, receivedAt: .now, on: database)
                            }
                            await locked.signal()
                            await release.wait()
                        }
                    } catch {
                        await locked.signal()
                        throw error
                    }
                }
                await locked.wait()
                let contender = Task {
                    if claimFirst {
                        return try await post("api/v1/devices/foreground-activity", body: payload(id, endpoint: "foreground-activity"), app: app).status
                    }
                    return try await enroll(id, credential: owner, app: app).status
                }
                do {
                    let sql = try #require(app.db as? any SQLDatabase)
                    var observedWait = false
                    for _ in 0..<200 {
                        let row = try await sql.raw("""
                            SELECT count(*)::int AS count FROM pg_stat_activity
                            WHERE datname = current_database() AND wait_event = 'advisory'
                            """).first()
                        if try row?.decode(column: "count", as: Int.self) ?? 0 > 0 {
                            observedWait = true
                            break
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    #expect(observedWait, "The contender must block on the installation lock before commit")
                    await release.signal()
                    try await holder.value
                    #expect(try await contender.value == (claimFirst ? .unauthorized : .ok))
                    let activity = try await sql.raw("SELECT 1 FROM installation_activity_daily WHERE installation_id = \(bind: id)").first()
                    #expect((activity != nil) == !claimFirst)
                    #expect(try await InstallationCredentialStore.load(id, on: app.db) != nil)
                } catch {
                    await release.signal()
                    _ = try? await holder.value
                    _ = try? await contender.value
                    throw error
                }
            }
        }
    }

    @Test("Competing first claims have one winner, including when no installation row exists")
    func concurrentClaims() async throws {
        try await withApp { (app: Application) async throws in
            // Boot once before issuing concurrent requests through the already-running responder.
            _ = try await app.testing().sendRequest(.GET, "health")
            for legacy in [false, true] {
                let id = newID()
                if legacy {
                    #expect(try await post("v1/devices/preferences", body: payload(id, endpoint: "preferences"), app: app).status == .ok)
                }
                async let first = enroll(id, credential: owner, app: app)
                async let second = enroll(id, credential: stranger, root: "api/", app: app)
                let results = try await [first.status, second.status]
                #expect(results.filter { $0 == .ok }.count == 1)
                #expect(results.filter { $0 == .conflict }.count == 1)
                let winner = results[0] == .ok ? owner : stranger
                #expect(try await enroll(id, credential: winner, app: app).status == .ok)
            }
        }
    }
}

private actor CredentialTestEvent {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
