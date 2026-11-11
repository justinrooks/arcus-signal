@testable import App
import ArcusCore
import Fluent
import FluentSQL
import FluentPostgresDriver
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
        let databaseURL = Environment.get("DATABASE_URL") ?? ""
        let name = URL(string: databaseURL)?.lastPathComponent ?? ""
        guard name.range(of: #"^arcus_issue[0-9]+_(test|validation)_[A-Za-z0-9_]+$"#, options: .regularExpression) != nil else {
            throw Abort(.internalServerError, reason: "An explicitly issue-scoped isolated test database is required")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            // Paused transactions, two HTTP writers, and the lock observer need four
            // connections even when Fluent assigns them to the same event loop.
            app.databases.use(try .postgres(url: databaseURL,
                maxConnectionsPerEventLoop: 4), as: .init(string: "issue406"), isDefault: true)
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
        try await sql.raw("DELETE FROM arcus_series WHERE id::text LIKE '03890000-%'").run()
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

    @Test("Observed location revocation fences old presence across restoration and replay")
    func revocationFence() async throws {
        try await withApp { app in
            app.mesoNotificationsEnabled = true
            for version in ["v3", "v4"] {
                for revokeAuthorization in [false, true] {
                    let id = id(); try await enroll(id, app: app)
                    var prefs = preferences(id)
                    prefs["apnsDeviceToken"] = "bound"
                    _ = try await post("v3/devices/preferences", prefs, app: app)
                    let path = "\(version)/devices/location-snapshots"
                    var old = location(id, capturedAt: Date().addingTimeInterval(version == "v4" ? 60 : -60))
                    old["cellScheme"] = "h3"; old["h3Cell"] = Int64(614934489169608703); old["h3Resolution"] = 8
                    old["zone"] = "COZ040"; old["fireZone"] = "COZ240"
                    old["countyLabel"] = "Denver"; old["fireZoneLabel"] = "Old fire zone"
                    #expect(try status(try await post(path, old, app: app)) == "accepted")
                    let seriesID = self.id(), urn = "urn:oid:\(UUID())", now = Date()
                    try await ArcusSeriesModel(id: seriesID, source: "nws", event: "Tornado Watch",
                        sourceURL: "https://api.weather.gov/alerts/\(seriesID)", currentRevisionUrn: urn,
                        currentRevisionSent: now, messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
                        state: EventState.active.rawValue, expires: now.addingTimeInterval(3600),
                        ends: now.addingTimeInterval(3600), lastSeenActive: now, severity: "severe",
                        urgency: "immediate", certainty: "observed", ugcCodes: ["COC031", "COC013"]).create(on: app.db)
                    try await ArcusEventRevisionModel(seriesId: seriesID, revisionUrn: urn, messageType: "alert",
                        sent: now, received: now, referencedUrns: []).create(on: app.db)
                    try await ArcusNotificationOutboxModel(series: seriesID, revisionUrn: urn,
                        mode: NotificationTargetMode.ugc.rawValue, reason: NotificationReason.new.rawValue,
                        state: "done", attempts: 1, availableAt: now).create(on: app.db)
                    let queued = try #require(app.queues.test.all(ReconcileInstallationAlertsJob.self).first { $0.installationId == id })
                    let context = QueueContext(queueName: ArcusQueueLane.target.queueName,
                        configuration: app.queues.configuration, application: app, logger: app.logger, on: app.eventLoopGroup.any())
                    let store = NotificationCandidateStore()
                    let candidate = try #require(try await store.loadH3Candidates(cells: [614934489169608703],
                        capturedAtOrAfter: .distantPast, installationId: id, on: app.db).first)
                    let intentCount = try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count()
                    var revoked = preferences(id, 2, sharing: revokeAuthorization)
                    if revokeAuthorization {
                        var consent = try #require(revoked["consent"] as? [String: Any])
                        consent["locationAuthorization"] = "denied"; revoked["consent"] = consent
                    }
                    #expect(try status(try await post("v3/devices/preferences", revoked, app: app)) == "accepted")
                    #expect(try status(try await post(path, old, app: app)) == "ignored")
                    let restored = try await post("v3/devices/preferences", preferences(id, 3), app: app)
                    #expect(try restored.content.decode(DevicePreferencesV3AcceptedResponse.self).serverOwnsMesoNotificationDelivery == false)
                    #expect(try status(try await post("v3/devices/preferences", preferences(id, 3), app: app)) == "unchanged")
                    #expect(try status(try await post("v3/devices/preferences", revoked, app: app)) == "stale")
                    #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count() == intentCount)
                    #expect(try await store.loadH3Candidates(cells: [614934489169608703], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).isEmpty)
                    #expect(try await store.loadUGCCandidates(ugcCodes: ["COC031", "COZ040", "COZ240"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).isEmpty)
                    let sendsBefore = app.queues.test.all(NotificationSendJob.self).count
                    try await ReconcileInstallationAlertsJob().reconcile(context, queued, on: app.db)
                    #expect(app.queues.test.all(NotificationSendJob.self).count == sendsBefore)
                    // A candidate loaded before revocation must also fail the shared post-claim gate.
                    #expect(try await store.acceptedConsentAllowsDelivery(candidate, on: app.db) == false)
                    #expect(try await store.acceptedConsentAllowsDelivery(candidate, meso: true, on: app.db) == false)
                    #expect(try status(try await post(path, old, app: app)) == "stale")
                    let invalidated = try #require(try await DevicePresenceModel.find(id, on: app.db))
                    #expect(invalidated.capturedAt == candidate.capturedAt)
                    #expect(invalidated.h3Cell == nil && invalidated.county == nil && invalidated.zone == nil && invalidated.fireZone == nil)
                    #expect(invalidated.countyLabel == nil && invalidated.fireZoneLabel == nil)
                    // Future relative to receipt is allowed within the existing five-minute skew bound.
                    let fresh = location(id, capturedAt: Date().addingTimeInterval(version == "v4" ? 62 : 2), county: "COC013")
                    #expect(try status(try await post(path, fresh, app: app)) == "accepted")
                    #expect(try await store.loadUGCCandidates(ugcCodes: ["COC013"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).map(\.id) == [id])
                    #expect(try await PresenceReconciliationOutboxModel.query(on: app.db).filter(\.$installation.$id == id).count() == intentCount + 1)
                    try await ReconcileInstallationAlertsJob().reconcile(context, queued, on: app.db)
                    #expect(app.queues.test.all(NotificationSendJob.self).count == sendsBefore + 1)
                    #expect(try status(try await post("v3/devices/preferences", preferences(id, 3), app: app)) == "unchanged")
                    #expect(try status(try await post(path, fresh, app: app)) == "accepted")
                    // Subscription-only transitions retain usable geography.
                    _ = try await post("v3/devices/preferences", preferences(id, 4, subscribed: false), app: app)
                    _ = try await post("v3/devices/preferences", preferences(id, 5), app: app)
                    #expect(try await store.loadUGCCandidates(ugcCodes: ["COC013"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).map(\.id) == [id])
                    try await ArcusSeriesModel.find(seriesID, on: app.db)?.delete(on: app.db)
                }
            }
        }
    }

    @Test("Location fence migration preserves legacy geography and fences already revoked consent")
    func revocationFenceMigration() async throws {
        try await withApp { app in
            let revokedID = id(), legacyID = id(), capturedAt = Date().addingTimeInterval(120)
            for id in [revokedID, legacyID] {
                try await enroll(id, app: app)
                _ = try await post("v3/devices/preferences", preferences(id), app: app)
                _ = try await post("v4/devices/location-snapshots", location(id, capturedAt: capturedAt), app: app)
            }
            try await withRollbackTransaction(on: app) { database in
                let sql = try #require(database as? any SQLDatabase)
                try await sql.raw("UPDATE device_installations SET location_sharing_enabled = FALSE WHERE installation_id = \(bind: revokedID)").run()
                try await sql.raw("UPDATE device_installations SET consent_revision = NULL WHERE installation_id = \(bind: legacyID)").run()
                try await AddLocationEvidenceFence().revert(on: database)
                try await AddLocationEvidenceFence().prepare(on: database)
                let revoked = try #require(try await DeviceInstallationModel.find(revokedID, on: database))
                let presence = try #require(try await DevicePresenceModel.find(revokedID, on: database))
                #expect(revoked.locationEvidenceNotBefore == presence.capturedAt)
                #expect(presence.county == nil)
                #expect(try await DeviceInstallationModel.find(legacyID, on: database)?.locationEvidenceNotBefore == nil)
                #expect(try await DevicePresenceModel.find(legacyID, on: database)?.county == "COC031")
                do {
                    try await AddLocationEvidenceFence().revert(on: database)
                    Issue.record("A populated location fence must block rollback")
                } catch let error as Abort { #expect(error.status == .conflict) }
            }
        }
    }

    @Test("Migration backfill time follows a revocation committed during its DDL lock wait")
    func delayedRevocationFenceMigration() async throws {
        try await withApp { app in
            let id = id(); try await enroll(id, app: app)
            _ = try await post("v3/devices/preferences", preferences(id), app: app)
            _ = try await post("v4/devices/location-snapshots", location(id, capturedAt: Date().addingTimeInterval(-60)), app: app)
            let original = try #require(try await DevicePresenceModel.find(id, on: app.db))
            try await AddLocationEvidenceFence().revert(on: app.db)
            let locked = V3TestEvent(), release = V3TestEvent()
            // Simulate a pre-migration preference writer retaining its table lock until commit.
            let writer = Task {
                try await app.db.transaction { database in
                    try await InstallationCredentialStore.lock(id, on: database)
                    let sql = try #require(database as? any SQLDatabase)
                    try await sql.raw("LOCK TABLE device_installations IN ROW EXCLUSIVE MODE").run()
                    await locked.signal(); await release.wait()
                    try await sql.raw("UPDATE device_installations SET location_sharing_enabled = FALSE, consent_revision = 2 WHERE installation_id = \(bind: id)").run()
                    let row = try #require(try await sql.raw("SELECT clock_timestamp() AS revoked_at").first())
                    return try row.decode(column: "revoked_at", as: Date.self)
                }
            }
            await locked.wait()
            let migration = Task { try await AddLocationEvidenceFence().prepare(on: app.db) }
            do {
                let sql = try #require(app.db as? any SQLDatabase)
                var observedWait = false
                for _ in 0..<500 {
                    let row = try #require(try await sql.raw("""
                        SELECT EXISTS(SELECT 1 FROM pg_locks
                        WHERE relation = 'device_installations'::regclass
                          AND mode = 'AccessExclusiveLock' AND NOT granted) AS waiting
                        """).first())
                    if try row.decode(column: "waiting", as: Bool.self) { observedWait = true; break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                try #require(observedWait, "Migration must be blocked on the real DDL lock")
                // Evidence captured after transaction start but before the writer revokes consent.
                let row = try #require(try await sql.raw("SELECT clock_timestamp() AS captured_at").first())
                let bufferedCapture = try row.decode(column: "captured_at", as: Date.self)
                await release.signal()
                let revokedAt = try await writer.value
                try await migration.value
                let installation = try #require(try await DeviceInstallationModel.find(id, on: app.db))
                let fence = try #require(installation.locationEvidenceNotBefore)
                #expect(fence >= revokedAt)
                #expect(fence > bufferedCapture)
                let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(presence.capturedAt == original.capturedAt && presence.county == nil)
                _ = try await post("v3/devices/preferences", preferences(id, 3), app: app)
                #expect(try status(try await post("v4/devices/location-snapshots", location(id, capturedAt: bufferedCapture), app: app)) == "stale")
            } catch {
                await release.signal()
                _ = try? await writer.value; _ = try? await migration.value
                throw error
            }
        }
    }

    @Test("V4 movement clears enrichment while V3 retains legacy patches")
    func versionedMovement() async throws {
        try await withApp { app in
            for version in ["v3", "v4"] {
                let id = id()
                try await enroll(id, app: app)
                var prefs = preferences(id)
                prefs["apnsDeviceToken"] = "bound"
                _ = try await post("v3/devices/preferences", prefs, app: app)
                // Initial H3-only admission needs no enrichment and uses the same authority.
                var minimal = location(id, capturedAt: Date().addingTimeInterval(-90))
                minimal.removeValue(forKey: "county")
                minimal["cellScheme"] = "h3"
                minimal["h3Cell"] = Int64(614934489169608703)
                minimal["h3Resolution"] = 8
                #expect(try await post("v4/devices/location-snapshots", minimal, app: app, authorized: false).status == .unauthorized)
                #expect(try status(try await post("v4/devices/location-snapshots", minimal, app: app)) == "accepted")
                let seriesID = self.id()
                let urn = "urn:oid:\(UUID())"
                let now = Date()
                try await ArcusSeriesModel(id: seriesID, source: "nws", event: "Tornado Watch",
                    sourceURL: "https://api.weather.gov/alerts/\(seriesID)", currentRevisionUrn: urn,
                    currentRevisionSent: now, messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
                    state: EventState.active.rawValue, expires: now.addingTimeInterval(3600),
                    ends: now.addingTimeInterval(3600), lastSeenActive: now, severity: "severe",
                    urgency: "immediate", certainty: "observed", ugcCodes: ["COC031"]).create(on: app.db)
                try await ArcusEventRevisionModel(seriesId: seriesID, revisionUrn: urn, messageType: "alert",
                    sent: now, received: now, referencedUrns: []).create(on: app.db)
                try await ArcusNotificationOutboxModel(series: seriesID, revisionUrn: urn,
                    mode: NotificationTargetMode.ugc.rawValue, reason: NotificationReason.new.rawValue,
                    state: "done", attempts: 1, availableAt: now).create(on: app.db)
                let time = Date().addingTimeInterval(-60)
                var initial = location(id, capturedAt: time)
                initial["cellScheme"] = "h3"
                initial["h3Cell"] = Int64(614934489169608703)
                initial["h3Resolution"] = 8
                initial["zone"] = "COZ040"
                initial["fireZone"] = "COZ240"
                initial["countyLabel"] = "Denver"
                initial["fireZoneLabel"] = "Old fire zone"
                let path = "\(version)/devices/location-snapshots"
                #expect(try await post(path, initial, app: app).status == .ok)
                if version == "v4" {
                    let beforeInvalid = try await snapshot(id, app: app)
                    // Exercise the shared DTO decoder through the authenticated controller:
                    // missing and explicit null fields must never refresh old geography.
                    for fields in [["h3Cell"], ["h3Resolution"], ["h3Cell", "h3Resolution"]] {
                        for explicitNull in [false, true] {
                            var incomplete = initial
                            incomplete["capturedAt"] = ISO8601DateFormatter().string(from: time.addingTimeInterval(10))
                            for key in fields {
                                if explicitNull { incomplete[key] = NSNull() }
                                else { incomplete.removeValue(forKey: key) }
                            }
                            #expect(try await post(path, incomplete, app: app).status == .badRequest)
                            #expect(try await snapshot(id, app: app) == beforeInvalid)
                            let falselyFreshCandidates = try await NotificationCandidateStore().loadUGCCandidates(
                                ugcCodes: ["COC031", "COZ040", "COZ240"],
                                capturedAtOrAfter: time.addingTimeInterval(1), installationId: id, on: app.db)
                            #expect(falselyFreshCandidates.isEmpty)
                        }
                    }
                }
                var movement = initial
                movement["capturedAt"] = ISO8601DateFormatter().string(from: time.addingTimeInterval(20))
                movement["h3Cell"] = Int64(614934489169608704)
                for key in ["county", "zone", "fireZone", "countyLabel", "fireZoneLabel"] { movement.removeValue(forKey: key) }
                #expect(try status(try await post(path, movement, app: app)) == "accepted")
                let moved = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(moved.county == (version == "v4" ? nil : "COC031"))
                #expect(moved.zone == (version == "v4" ? nil : "COZ040"))
                #expect(moved.fireZone == (version == "v4" ? nil : "COZ240"))
                #expect(moved.countyLabel == (version == "v4" ? nil : "Denver"))
                #expect(moved.fireZoneLabel == (version == "v4" ? nil : "Old fire zone"))
                let store = NotificationCandidateStore()
                let matches = try await store.loadMatchingActiveAlerts(for: id, evaluatedAt: .now, on: app.db)
                #expect(matches.contains { $0.seriesId == seriesID } == (version == "v3"))
                let oldCandidates = try await store.loadUGCCandidates(ugcCodes: ["COC031", "COZ040", "COZ240"], capturedAtOrAfter: .distantPast, installationId: id, on: app.db)
                #expect(oldCandidates.isEmpty == (version == "v4"))
                #expect(try await store.loadH3Candidates(cells: [614934489169608704], capturedAtOrAfter: .distantPast, installationId: id, on: app.db).map(\.id) == [id])
                // Older observations cannot revive the old scopes.
                let beforeStale = try await snapshot(id, app: app)
                #expect(try status(try await post(path, initial, app: app)) == "stale")
                #expect(try await snapshot(id, app: app) == beforeStale)
                movement["county"] = "COC013"
                movement["countyLabel"] = "Boulder"
                #expect(try status(try await post(path, movement, app: app)) == "accepted")
                movement.removeValue(forKey: "county")
                movement.removeValue(forKey: "countyLabel")
                #expect(try status(try await post(path, movement, app: app)) == "accepted")
                let enriched = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(enriched.county == "COC013" && enriched.countyLabel == "Boulder")
                if version == "v4" {
                    // A partial movement replaces the county and invalidates all omitted enrichment.
                    movement["h3Cell"] = Int64(614934489169608705)
                    movement["county"] = "COC001"
                    // A changed identity needs newer capture evidence under V4.
                    movement["capturedAt"] = ISO8601DateFormatter().string(from: time.addingTimeInterval(21))
                    #expect(try status(try await post(path, movement, app: app)) == "accepted")
                    let partial = try #require(try await DevicePresenceModel.find(id, on: app.db))
                    #expect(partial.county == "COC001" && partial.countyLabel == nil)
                    #expect(partial.zone == nil && partial.fireZone == nil && partial.fireZoneLabel == nil)
                }
                try await ArcusSeriesModel.find(seriesID, on: app.db)?.delete(on: app.db)
            }
        }
    }

    @Test("V4 same-cell captures retire old UGC and reconcile active alerts after enrichment")
    func sameCellEnrichment() async throws {
        try await withApp { app in
            for codeKey in ["county", "zone", "fireZone"] {
                let id = id(); try await enroll(id, app: app)
                var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
                _ = try await post("v3/devices/preferences", prefs, app: app)
                let path = "v4/devices/location-snapshots"
                let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
                var initial = location(id, capturedAt: time)
                initial["cellScheme"] = "h3"; initial["h3Cell"] = Int64(614934489169608703)
                initial["h3Resolution"] = 8
                initial["zone"] = "COZ040"; initial["fireZone"] = "COZ240"
                initial["countyLabel"] = "Denver"; initial["fireZoneLabel"] = "Old fire zone"
                #expect(try status(try await post(path, initial, app: app)) == "accepted")
                let newCode = codeKey == "county" ? "COC013" : (codeKey == "zone" ? "COZ041" : "COZ241")
                let seriesID = self.id(), urn = "urn:oid:\(UUID())", now = Date()
                // The alert is already active before B's minimal upload or enrichment.
                try await ArcusSeriesModel(id: seriesID, source: "nws", event: "Tornado Watch",
                    sourceURL: "https://api.weather.gov/alerts/\(seriesID)", currentRevisionUrn: urn,
                    currentRevisionSent: now, messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
                    state: EventState.active.rawValue, expires: now.addingTimeInterval(3600),
                    ends: now.addingTimeInterval(3600), lastSeenActive: now, severity: "severe",
                    urgency: "immediate", certainty: "observed", ugcCodes: [newCode]).create(on: app.db)
                try await ArcusEventRevisionModel(seriesId: seriesID, revisionUrn: urn, messageType: "alert",
                    sent: now, received: now, referencedUrns: []).create(on: app.db)
                try await ArcusNotificationOutboxModel(series: seriesID, revisionUrn: urn,
                    mode: NotificationTargetMode.ugc.rawValue, reason: NotificationReason.new.rawValue,
                    state: "done", attempts: 1, availableAt: now).create(on: app.db)
                var minimal = initial
                minimal["capturedAt"] = ISO8601DateFormatter().string(from: time.addingTimeInterval(20))
                for key in ["county", "zone", "fireZone", "countyLabel", "fireZoneLabel"] { minimal.removeValue(forKey: key) }
                #expect(try status(try await post(path, minimal, app: app)) == "accepted")
                let incomplete = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(incomplete.capturedAt == time.addingTimeInterval(20))
                #expect(incomplete.county == nil && incomplete.zone == nil && incomplete.fireZone == nil)
                #expect(incomplete.countyLabel == nil && incomplete.fireZoneLabel == nil)
                let store = NotificationCandidateStore()
                #expect(try await store.loadUGCCandidates(ugcCodes: ["COC031", "COZ040", "COZ240"],
                    capturedAtOrAfter: .distantPast, installationId: id, on: app.db).isEmpty)
                #expect(try await store.loadH3Candidates(cells: [614934489169608703],
                    capturedAtOrAfter: time.addingTimeInterval(1), installationId: id, on: app.db).map(\.id) == [id])
                let context = QueueContext(queueName: ArcusQueueLane.target.queueName,
                    configuration: app.queues.configuration, application: app, logger: app.logger, on: app.eventLoopGroup.any())
                let queued = try #require(app.queues.test.all(ReconcileInstallationAlertsJob.self).last { $0.installationId == id })
                try await ReconcileInstallationAlertsJob().dequeue(context, queued)
                #expect(app.queues.test.all(NotificationSendJob.self).filter { $0.installationId == id }.isEmpty)
                // Partial B enrichment can fill one code; a delayed A must never restore old codes.
                var enriched = minimal; enriched[codeKey] = newCode
                #expect(try status(try await post(path, enriched, app: app)) == "accepted")
                let current = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(current.county == (codeKey == "county" ? newCode : nil))
                #expect(current.zone == (codeKey == "zone" ? newCode : nil))
                #expect(current.fireZone == (codeKey == "fireZone" ? newCode : nil))
                let beforeRetry = try await snapshot(id, app: app)[3]
                #expect(try status(try await post(path, enriched, app: app)) == "accepted")
                #expect(try status(try await post(path, minimal, app: app)) == "accepted")
                #expect(try await snapshot(id, app: app)[3] == beforeRetry)
                let beforeStale = try await snapshot(id, app: app)
                #expect(try status(try await post(path, initial, app: app)) == "stale")
                var conflict = enriched; conflict[codeKey] = initial[codeKey]
                #expect(try status(try await post(path, conflict, app: app)) == "stale")
                #expect(try await snapshot(id, app: app) == beforeStale)
                let intents = try await PresenceReconciliationOutboxModel.query(on: app.db)
                    .filter(\.$installation.$id == id).all()
                #expect(intents.count == 3 && intents.allSatisfy { $0.state == .done })
                let complete = try #require(app.queues.test.all(ReconcileInstallationAlertsJob.self).last { $0.installationId == id })
                #expect(complete.intentId != queued.intentId)
                try await ReconcileInstallationAlertsJob().dequeue(context, complete)
                let sends = app.queues.test.all(NotificationSendJob.self).filter { $0.installationId == id }
                #expect(sends.count == 1 && sends.first?.seriesId == seriesID && sends.first?.revisionUrn == urn)
                try await ArcusSeriesModel.find(seriesID, on: app.db)?.delete(on: app.db)
            }
        }
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
            #expect(!response.serverOwnsMesoNotificationDelivery)
            #expect(try await DeviceInstallationModel.find(id, on: app.db)?.apnsDeviceToken == "")
            var binding = preferences(id)
            binding["apnsDeviceToken"] = "rotated-token"
            binding["apnsEnvironment"] = "prod"
            let bound = try await post("api/v3/devices/preferences", binding, app: app)
            let boundResponse = try bound.content.decode(DevicePreferencesV3AcceptedResponse.self)
            #expect(boundResponse.status == .unchanged && boundResponse.acceptedConsentRevision == 1)
            #expect(!boundResponse.serverOwnsMesoNotificationDelivery)
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

    @Test("Meso ownership requires accepted usable H3 presence and refreshes without a new consent revision")
    func mesoOwnership() async throws {
        try await withApp { app in
            app.mesoNotificationsEnabled = true
            let id = id(); try await enroll(id, app: app)
            var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
            func owns(_ body: [String: Any]) async throws -> Bool {
                let response = try await post("v3/devices/preferences", body, app: app)
                #expect(response.status == .ok)
                return try response.content.decode(DevicePreferencesV3AcceptedResponse.self).serverOwnsMesoNotificationDelivery
            }
            #expect(try await !owns(prefs))
            // Accepted county-only presence is useful for NWS, but cannot target mesos.
            #expect(try status(try await post("v3/devices/location-snapshots", location(id), app: app)) == "accepted")
            #expect(try await !owns(prefs))
            var h3 = location(id)
            h3["cellScheme"] = "h3"; h3["h3Cell"] = Int64(614934489169608703); h3["h3Resolution"] = 8
            #expect(try status(try await post("api/v3/devices/location-snapshots", h3, app: app)) == "accepted")
            #expect(try await owns(prefs))
            let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
            let capturedAt = presence.capturedAt
            presence.h3Resolution = 7; try await presence.save(on: app.db)
            #expect(try await !owns(prefs))
            presence.h3Resolution = 8
            presence.cellScheme = .ugcOnly; presence.h3Cell = nil; presence.county = nil
            try await presence.save(on: app.db)
            #expect(try await !owns(prefs))
            presence.cellScheme = .h3; presence.h3Cell = 614934489169608703
            // Degraded presence remains eligible; hard stale presence does not.
            presence.capturedAt = Date().addingTimeInterval(-7 * 3600); try await presence.save(on: app.db)
            #expect(try await owns(prefs))
            presence.capturedAt = Date().addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold - 60)
            try await presence.save(on: app.db)
            #expect(try await !owns(prefs))
            var newer = preferences(id, 2)
            #expect(try await !owns(newer))
            // Stale-revision responses must also use current accepted presence.
            #expect(try await !owns(prefs))
            presence.capturedAt = capturedAt; try await presence.save(on: app.db)
            #expect(try await owns(prefs))
            app.mesoNotificationsEnabled = false
            #expect(try await !owns(newer))
            app.mesoNotificationsEnabled = true
            let installation = try #require(try await DeviceInstallationModel.find(id, on: app.db))
            installation.apnsDeviceToken = ""; try await installation.save(on: app.db)
            #expect(try await !owns(newer))
            newer["apnsDeviceToken"] = "bound"
            #expect(try await owns(newer))
            for (offset, field) in ["isSubscribed", "mesoNotificationsEnabled", "locationSharingEnabled", "locationAuthorization"].enumerated() {
                var denied = preferences(id, Int64(3 + offset))
                var consent = try #require(denied["consent"] as? [String: Any])
                consent[field] = field == "locationAuthorization" ? "denied" : false
                denied["consent"] = consent
                #expect(try await !owns(denied))
            }
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

    @Test("A selected candidate needs an existing installation, including before v3 promotion")
    func missingInstallationFailsClosed() async throws {
        try await withApp { app in
            let id = id(); try await enroll(id, app: app)
            var legacy = location(id)
            legacy.merge(["apnsDeviceToken": "bound", "apnsEnvironment": "sandbox", "platform": "iOS",
                          "osVersion": "26", "appVersion": "1", "buildNumber": "1", "auth": "always",
                          "isSubscribed": true]) { _, new in new }
            #expect(try await post("v2/devices/location-snapshots", legacy, app: app).status == .ok)
            let store = NotificationCandidateStore()
            let candidate = try #require(try await store.loadUGCCandidates(ugcCodes: ["COC031"],
                capturedAtOrAfter: .distantPast, installationId: id, on: app.db).first)
            let installation = try #require(try await DeviceInstallationModel.find(id, on: app.db))
            #expect(installation.consentRevision == nil)
            for meso in [false, true] {
                #expect(try await store.acceptedConsentAllowsDelivery(candidate, meso: meso, on: app.db))
            }
            try await installation.delete(on: app.db)
            for meso in [false, true] {
                #expect(try await !store.acceptedConsentAllowsDelivery(candidate, meso: meso, on: app.db))
            }
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
            for kind in ["preferences", "location-snapshots", "v4-location-snapshots", "legacy"] {
                for revokeFirst in [false, true] {
                    let id = id(); try await enroll(id, app: app)
                    if kind != "legacy" {
                        _ = try await post("v3/devices/preferences", preferences(id), app: app)
                        _ = try await post("v3/devices/location-snapshots", location(id, capturedAt: Date().addingTimeInterval(-1)), app: app)
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
                    case "location-snapshots", "v4-location-snapshots": otherPath = "\(kind == "location-snapshots" ? "v3" : "v4")/devices/location-snapshots"; otherBody = location(id, county: "COC013")
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
                            if revokeFirst && kind.hasSuffix("location-snapshots") {
                                #expect(try status(results.1) == "ignored")
                                #expect(try await snapshot(id, app: app)[2...] == before[2...])
                                #expect(try await DevicePresenceModel.find(id, on: app.db)?.county == nil)
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
                    if kind.hasSuffix("location-snapshots") {
                        // The same fence must survive either actual transaction commit order.
                        _ = try await post(revokePath, preferences(id, 4), app: app)
                        #expect(try status(try await postData(otherPath, data: otherData, app: app)) == "stale")
                        #expect(try await DevicePresenceModel.find(id, on: app.db)?.county == nil)
                    }
                }
            }
        }
    }

    @Test("V3 and V4 serialize first presence and updates before comparing captures")
    func presenceOrdering() async throws {
        try await withApp { app in
            let sql = try #require(app.db as? any SQLDatabase)
            for version in ["v3", "v4"] {
                for seeded in [false, true] {
                    for newerFirst in [false, true] {
                        let id = id(); try await enroll(id, app: app)
                        var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
                        _ = try await post("v3/devices/preferences", prefs, app: app)
                        let path = "\(version)/devices/location-snapshots"
                        let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 30)
                        if seeded {
                            _ = try await post(path, location(id, capturedAt: base, county: "COC001"), app: app)
                        }
                        let olderCapture = base.addingTimeInterval(version == "v4" ? 0.1 : 1)
                        let newerCapture = base.addingTimeInterval(version == "v4" ? 0.9 : 2)
                        var olderBody = location(id, capturedAt: olderCapture, county: "COC013")
                        var newerBody = location(id, capturedAt: newerCapture, county: "COC031")
                        if version == "v4" {
                            let second = ISO8601DateFormatter().string(from: base).dropLast()
                            olderBody["capturedAt"] = "\(second).100000000Z"
                            newerBody["capturedAt"] = "\(second).900000000Z"
                        }
                        let older = try JSONSerialization.data(withJSONObject: olderBody)
                        let newer = try JSONSerialization.data(withJSONObject: newerBody)
                        // Pause the actual first HTTP mutation after its write, while it still owns
                        // the installation lock. The second must wait before reading any presence.
                        try await sql.raw("""
                            CREATE FUNCTION issue406_pause() RETURNS trigger LANGUAGE plpgsql AS $$
                            BEGIN PERFORM pg_advisory_xact_lock(406, 1); RETURN NEW; END $$
                            """).run()
                        try await sql.raw("""
                            CREATE TRIGGER issue406_pause AFTER INSERT OR UPDATE ON device_presence
                            FOR EACH ROW WHEN (NEW.installation_id = '\(unsafeRaw: id.uuidString)'::uuid)
                            EXECUTE FUNCTION issue406_pause()
                            """).run()
                        let locked = V3TestEvent(), release = V3TestEvent()
                        let blocker = Task {
                            try await app.db.transaction { database in
                                let connection = try #require(database as? any SQLDatabase)
                                try await connection.raw("SELECT pg_advisory_xact_lock(406, 1)").run()
                                await locked.signal(); await release.wait()
                            }
                        }
                        await locked.wait()
                        let first = Task { try await postData(path, data: newerFirst ? newer : older, app: app) }
                        do {
                            try await waitForAdvisoryWaiters(1, sql: sql)
                            let second = Task { try await postData(path, data: newerFirst ? older : newer, app: app) }
                            do {
                                try await waitForAdvisoryWaiters(2, sql: sql)
                                await release.signal()
                                try await blocker.value
                                let results = try await (first.value, second.value)
                                #expect(try status(results.0) == "accepted")
                                #expect(try status(results.1) == (newerFirst ? "stale" : "accepted"))
                                let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
                                #expect(abs(presence.capturedAt.timeIntervalSince(newerCapture)) < 0.000001)
                                #expect(presence.county == "COC031")
                                let intents = try await PresenceReconciliationOutboxModel.query(on: app.db)
                                    .filter(\.$installation.$id == id).all()
                                #expect(intents.count == (seeded ? 1 : 0) + (newerFirst ? 1 : 2))
                                #expect(intents.contains { abs($0.presenceCapturedAt.timeIntervalSince(newerCapture)) < 0.000001 })
                                if newerFirst {
                                    #expect(!intents.contains { abs($0.presenceCapturedAt.timeIntervalSince(olderCapture)) < 0.000001 })
                                }
                                let beforeReplay = try await snapshot(id, app: app)
                                #expect(try status(try await postData(path, data: older, app: app)) == "stale")
                                #expect(try await snapshot(id, app: app) == beforeReplay)
                            } catch {
                                await release.signal(); _ = try? await second.value; throw error
                            }
                        } catch {
                            await release.signal(); _ = try? await first.value; _ = try? await blocker.value
                            try? await dropPresencePause(sql); throw error
                        }
                        try await dropPresencePause(sql)
                    }
                }
            }
        }
    }

    private func dropPresencePause(_ sql: any SQLDatabase) async throws {
        try await sql.raw("DROP TRIGGER IF EXISTS issue406_pause ON device_presence").run()
        try await sql.raw("DROP FUNCTION IF EXISTS issue406_pause()").run()
    }

    @Test("Whole-second collisions preserve V3 arrival order and fail closed on V4 conflicts")
    func equalCapture() async throws {
        try await withApp { app in
            for version in ["v3", "v4"] {
                let id = id(); try await enroll(id, app: app)
                var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
                _ = try await post("v3/devices/preferences", prefs, app: app)
                let path = "\(version)/devices/location-snapshots"
                let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 30)
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                func observation(_ offset: Double, _ county: String) throws -> Data {
                    try encoder.encode(DeviceLocationSnapshotV3Payload(installationId: id.uuidString,
                        capturedAt: base.addingTimeInterval(offset), locationAgeSeconds: 0,
                        horizontalAccuracyMeters: 10, cellScheme: "ugc-only", h3Cell: nil, h3Resolution: nil,
                        county: county, zone: nil, fireZone: nil, countyLabel: nil, fireZoneLabel: nil, source: .foregroundPrime))
                }
                let older = try observation(0.1, "COC013"), newer = try observation(0.9, "COC031")
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                #expect(try decoder.decode(DeviceLocationSnapshotV3Payload.self, from: older).capturedAt == base)
                #expect(try decoder.decode(DeviceLocationSnapshotV3Payload.self, from: newer).capturedAt == base)
                #expect(try status(try await postData(path, data: newer, app: app)) == "accepted")
                let intentsBefore = try await snapshot(id, app: app)[3]
                #expect(try status(try await postData(path, data: newer, app: app)) == "accepted")
                #expect(try await snapshot(id, app: app)[3] == intentsBefore)
                let beforeConflict = try await snapshot(id, app: app)
                #expect(try status(try await postData(path, data: older, app: app)) == (version == "v4" ? "stale" : "accepted"))
                let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(presence.capturedAt == base)
                #expect(presence.county == (version == "v4" ? "COC031" : "COC013"))
                if version == "v4" { #expect(try await snapshot(id, app: app) == beforeConflict) }
                let intents = try await PresenceReconciliationOutboxModel.query(on: app.db)
                    .filter(\.$installation.$id == id).all()
                #expect(intents.count == (version == "v4" ? 1 : 2))
            }
        }
    }

    @Test("V4 fractional ingress preserves chronology, compatible enrichment, and database precision ties")
    func fractionalPresence() async throws {
        try await withApp { app in
            for crossCell in [false, true] {
                let id = id(); try await enroll(id, app: app)
                var prefs = preferences(id); prefs["apnsDeviceToken"] = "bound"
                _ = try await post("v3/devices/preferences", prefs, app: app)
                let path = "v4/devices/location-snapshots"
                let base = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 30)
                let second = ISO8601DateFormatter().string(from: base).dropLast()
                var newer = location(id, capturedAt: base)
                newer["capturedAt"] = "\(second).900000000Z"
                newer["cellScheme"] = "h3"; newer["h3Resolution"] = 8
                newer["h3Cell"] = Int64(614934489169608703)
                newer["zone"] = "COZ040"; newer["fireZone"] = "COZ240"
                // Accept H3-only first, then compatible enrichment at the same capture.
                var minimal = newer
                for key in ["county", "zone", "fireZone"] { minimal.removeValue(forKey: key) }
                #expect(try status(try await post(path, minimal, app: app)) == "accepted")
                #expect(try status(try await post(path, newer, app: app)) == "accepted")
                let intentsBeforeRetry = try await snapshot(id, app: app)[3]
                var sameTickMinimal = minimal
                sameTickMinimal["capturedAt"] = "\(second).900000100Z"
                #expect(try status(try await post(path, sameTickMinimal, app: app)) == "accepted")
                let afterSameTick = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(afterSameTick.county == "COC031" && afterSameTick.zone == "COZ040" && afterSameTick.fireZone == "COZ240")
                #expect(try status(try await post(path, newer, app: app)) == "accepted")
                #expect(try status(try await post(path, minimal, app: app)) == "accepted")
                #expect(try await snapshot(id, app: app)[3] == intentsBeforeRetry)
                var older = newer
                older["capturedAt"] = "\(second).100000000Z"
                older["county"] = "COC013"; older["zone"] = "COZ041"; older["fireZone"] = "COZ241"
                if crossCell { older["h3Cell"] = Int64(614934489186385919) }
                let before = try await snapshot(id, app: app)
                // Reverse arrival/completion: delayed A cannot replace B or enqueue movement.
                #expect(try status(try await post(path, older, app: app)) == "stale")
                older["capturedAt"] = ISO8601DateFormatter().string(from: base.addingTimeInterval(-1))
                #expect(try status(try await post(path, older, app: app)) == "stale")
                for key in ["county", "zone", "fireZone", "h3Cell", "h3Resolution", "cellScheme"] {
                    var conflicting = newer
                    switch key {
                    case "h3Cell": conflicting[key] = Int64(614934489186385919)
                    case "h3Resolution": conflicting[key] = 7
                    case "cellScheme": conflicting[key] = "ugc-only"
                    default: conflicting[key] = older[key]
                    }
                    #expect(try status(try await post(path, conflicting, app: app)) == "stale")
                }
                // Distinct Dates below database resolution must use the same fail-safe.
                older["capturedAt"] = "\(second).900000100Z"
                #expect(try status(try await post(path, older, app: app)) == "stale")
                #expect(try await snapshot(id, app: app) == before)
                let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
                #expect(abs(presence.capturedAt.timeIntervalSince(base) - 0.9) < 0.000001)
                #expect(presence.county == "COC031" && presence.zone == "COZ040" && presence.fireZone == "COZ240")
                // A genuinely newer fractional capture still owns movement invalidation.
                older["capturedAt"] = "\(second).950000000Z"
                #expect(try status(try await post(path, older, app: app)) == "accepted")
            }
        }
    }

    @Test("Actual SkyAware uploader bodies decode at authenticated V4 ingress")
    func uploaderWireBodies() async throws {
        // Exported from SkyAware HTTPLocationSnapshotUploaderTests XCResult attachments.
        let oldA = #"{"county":"COC001","h3Cell":613725958748241919,"zone":"COZ245","h3Resolution":8,"capturedAt":"2024-03-09T16:00:00Z","installationId":"f0465f55-f0a2-48a0-aac0-6a5c48a95891","source":"unknown","locationAgeSeconds":5,"cellScheme":"h3","horizontalAccuracyMeters":12,"fireZone":"COZ245","countyLabel":"Adams County","fireZoneLabel":"Front Range"}"#
        let oldB = #"{"h3Cell":613725958748241919,"horizontalAccuracyMeters":12,"locationAgeSeconds":5,"installationId":"f0465f55-f0a2-48a0-aac0-6a5c48a95891","capturedAt":"2024-03-09T16:00:00Z","cellScheme":"h3","fireZone":"COZ245","source":"unknown","zone":"COZ245","countyLabel":"Adams County","h3Resolution":8,"county":"COC001","fireZoneLabel":"Front Range"}"#
        let newA = #"{"county":"COC001","installationId":"f0465f55-f0a2-48a0-aac0-6a5c48a95891","locationAgeSeconds":5,"zone":"COZ245","source":"unknown","capturedAt":"2024-03-09T16:00:00.100000024Z","fireZoneLabel":"Front Range","cellScheme":"h3","h3Cell":613725958748241919,"countyLabel":"Adams County","horizontalAccuracyMeters":12,"fireZone":"COZ245","h3Resolution":8}"#
        let newB = #"{"installationId":"f0465f55-f0a2-48a0-aac0-6a5c48a95891","countyLabel":"Adams County","h3Resolution":8,"zone":"COZ245","fireZoneLabel":"Front Range","cellScheme":"h3","county":"COC001","source":"unknown","h3Cell":613725958748241919,"fireZone":"COZ245","capturedAt":"2024-03-09T16:00:00.899999976Z","horizontalAccuracyMeters":12,"locationAgeSeconds":5}"#
        try await withApp { app in
            let id = id(); try await enroll(id, app: app)
            _ = try await post("v3/devices/preferences", preferences(id), app: app)
            func body(_ wire: String) throws -> [String: Any] {
                var value = try #require(JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any])
                // Isolate only installation identity; retain the uploader's exact capture/targeting fields.
                value["installationId"] = id.uuidString
                return value
            }
            #expect(try body(oldA)["capturedAt"] as? String == body(oldB)["capturedAt"] as? String)
            let path = "v4/devices/location-snapshots"
            #expect(try status(try await post(path, body(oldA), app: app)) == "accepted")
            #expect(try status(try await post(path, body(newB), app: app)) == "accepted")
            let before = try await snapshot(id, app: app)
            #expect(try status(try await post(path, body(newA), app: app)) == "stale")
            #expect(try await snapshot(id, app: app) == before)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(DeviceLocationSnapshotV3Payload.self, from: Data(newB.utf8))
            let presence = try #require(try await DevicePresenceModel.find(id, on: app.db))
            #expect(abs(presence.capturedAt.timeIntervalSince(decoded.capturedAt)) < 0.000001)
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
