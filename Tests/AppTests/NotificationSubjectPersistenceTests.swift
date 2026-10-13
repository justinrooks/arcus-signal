@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Notification subject persistence", .serialized)
struct NotificationSubjectPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("kind strings round-trip without an allowlist and reject blank values")
    func kindRepresentation() throws {
        for value in ["nws", "spc-meso", "test-product"] {
            let kind = try #require(NotificationSubject.Kind(rawValue: value))
            #expect(try JSONDecoder().decode(NotificationSubject.Kind.self, from: JSONEncoder().encode(kind)) == kind)
            #expect(NotificationSubject.resolve(kind: value, productID: "product", revisionID: "revision",
                                               seriesID: nil, revisionUrn: "revision")?.kind == kind)
        }
        #expect(NotificationSubject.Kind(rawValue: "nws") == .nws)
        #expect(NotificationSubject.Kind(rawValue: "spc-meso") == .spcMeso)
        for value in ["", " ", "\t\n\r", "\u{00A0}", "\u{2007}", "\u{202F}", "\u{200B}"] {
            #expect(NotificationSubject.Kind(rawValue: value) == nil)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(NotificationSubject.Kind.self, from: JSONEncoder().encode(value))
            }
        }
    }

    private func withDatabase(test: @escaping @Sendable (any Database) async throws -> Void) async throws {
        try await withIntegrationTestApplication(setup: .configured(mode: .api, migrate: true)) { app in
            try await withRollbackTransaction(on: app, test: test)
        }
    }

    private func seed(on db: any Database) async throws -> (series: UUID, installation: UUID) {
        let series = UUID()
        let installation = UUID()
        try await ArcusSeriesModel(
            id: series, source: "nws", event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/\(series)",
            currentRevisionUrn: "urn:oid:\(series)", currentRevisionSent: now,
            messageType: "alert", contentFingerprint: String(repeating: "a", count: 64),
            state: "active", lastSeenActive: now, severity: "severe",
            urgency: "immediate", certainty: "observed", ugcCodes: []
        ).create(on: db)
        try await DeviceInstallationModel(
            installationId: installation, apnsDeviceToken: "subject-test-token",
            apnsEnvironment: .sandbox, platform: .iOS, osVersion: "26.0",
            appVersion: "1.0.0", buildNumber: "100", locationAuth: .always,
            lastSeenAt: now, isSubscribed: true
        ).create(on: db)
        return (series, installation)
    }

    private func records(series: UUID?, installation: UUID, revision: String,
                         subject: NotificationSubject? = nil, on db: any Database) async throws
        -> (outbox: UUID, ledger: UUID, debug: UUID, attempt: UUID) {
        let outbox = ArcusNotificationOutboxModel(
            series: series, revisionUrn: revision, mode: "h3", reason: "new",
            state: "ready", attempts: 0, availableAt: now, subject: subject
        )
        let ledger = NotificationLedgerModel(
            installationId: installation, series: series, revisionUrn: revision,
            mode: "h3", reason: "new", freshnessState: .fresh, status: "claimed", subject: subject
        )
        try await outbox.create(on: db)
        try await ledger.create(on: db)
        let debug = NotificationDebugModel(
            seriesID: series, installationID: installation, notificationLedgerID: try ledger.requireID(),
            revisionUrn: revision, mode: "h3", reason: "new", recordKind: .candidate,
            title: "Test", subtitle: "", body: "Test", subject: subject
        )
        let attempt = NotificationSendAttemptModel(
            seriesID: series, revisionUrn: revision, mode: .h3, reason: .new,
            outcome: .delivered, candidateResolutionReached: true, candidateCount: 1,
            claimedCount: 1, sentCount: 1, failedCount: 0, attemptedAt: now, subject: subject
        )
        try await debug.create(on: db)
        try await attempt.create(on: db)
        return try (outbox.requireID(), ledger.requireID(), debug.requireID(), attempt.requireID())
    }

    private func expectSubjects(_ ids: (outbox: UUID, ledger: UUID, debug: UUID, attempt: UUID),
                                equal subject: NotificationSubject, on db: any Database) async throws {
        let outbox = try #require(try await ArcusNotificationOutboxModel.find(ids.outbox, on: db))
        let ledger = try #require(try await NotificationLedgerModel.find(ids.ledger, on: db))
        let debug = try #require(try await NotificationDebugModel.find(ids.debug, on: db))
        let attempt = try #require(try await NotificationSendAttemptModel.find(ids.attempt, on: db))
        #expect(outbox.subject == subject)
        #expect(ledger.subject == subject)
        #expect(debug.subject == subject)
        #expect(attempt.subject == subject)
    }

    private func expectRejected(on db: any Database, operation: () async throws -> Void) async throws {
        let sql = try #require(db as? any SQLDatabase)
        try await sql.raw("SAVEPOINT expected_rejection").run()
        await #expect(throws: (any Error).self) { try await operation() }
        try await sql.raw("ROLLBACK TO SAVEPOINT expected_rejection").run()
        try await sql.raw("RELEASE SAVEPOINT expected_rejection").run()
    }

    @Test("historical rows backfill and unchanged NWS writes retain claim and foreign key behavior")
    func legacyCompatibility() async throws {
        try await withDatabase { db in
            let sql = try #require(db as? any SQLDatabase)
            let fixture = try await seed(on: db)
            let revision = "urn:oid:\(UUID())"
            let ids = try await records(series: fixture.series, installation: fixture.installation,
                                        revision: revision, on: db)
            try await MakeNotificationSubjectKindsExtensible().revert(on: db)
            try await AddNotificationSubjectIdentity().revert(on: db)
            // The rows now exist in the physical pre-change schema.
            let old = try #require(try await sql.raw("SELECT series_id, revision_urn FROM notification_ledger WHERE id = \(bind: ids.ledger)").first())
            #expect(try old.decode(column: "series_id", as: UUID.self) == fixture.series)
            #expect(try old.decode(column: "revision_urn", as: String.self) == revision)
            try await AddNotificationSubjectIdentity().prepare(on: db)
            try await MakeNotificationSubjectKindsExtensible().prepare(on: db)
            let subject = NotificationSubject.nws(seriesID: fixture.series, revisionUrn: revision)
            try await expectSubjects(ids, equal: subject, on: db)
            for (table, id) in [("notification_outbox", ids.outbox), ("notification_ledger", ids.ledger),
                                ("notification_debug", ids.debug), ("notification_send_attempts", ids.attempt)] {
                let row = try #require(try await sql.raw("SELECT subject_kind, subject_id, subject_revision_id FROM \(ident: table) WHERE id = \(bind: id)").first())
                #expect(try row.decode(column: "subject_kind", as: String.self) == "nws")
                #expect(try row.decode(column: "subject_id", as: String.self) == subject.productID)
                #expect(try row.decode(column: "subject_revision_id", as: String.self) == revision)
            }
            // An unchanged raw SQL claim must still conflict across H3 and UGC.
            let duplicate = try await NotificationDeliveryStore().claim(
                installationID: fixture.installation, seriesID: fixture.series, revisionUrn: revision,
                mode: .ugc, reason: .new, freshnessState: .fresh, on: db
            )
            #expect(!duplicate.inserted)
            try await NotificationDeliveryStore().completeSent(claimID: ids.ledger, on: db)
            #expect(try await NotificationLedgerModel.find(ids.ledger, on: db)?.status == "sent")

            let nextRevision = "urn:oid:\(UUID())"
            let freshIDs = try await records(series: fixture.series, installation: fixture.installation,
                                             revision: nextRevision, on: db)
            try await expectSubjects(freshIDs, equal: .nws(seriesID: fixture.series, revisionUrn: nextRevision), on: db)
            let rawRevision = "urn:oid:\(UUID())"
            let rawClaim = try await NotificationDeliveryStore().claim(
                installationID: fixture.installation, seriesID: fixture.series, revisionUrn: rawRevision,
                mode: .h3, reason: .new, freshnessState: .fresh, on: db
            )
            let rawLedger = try #require(try await NotificationLedgerModel.find(#require(rawClaim.id), on: db))
            #expect(rawLedger.subject == .nws(seriesID: fixture.series, revisionUrn: rawRevision))

            try await expectRejected(on: db) {
                _ = try await records(series: UUID(), installation: fixture.installation,
                                      revision: "urn:oid:invalid", on: db)
            }
            try await ArcusSeriesModel.query(on: db).filter(\.$id == fixture.series).delete()
            #expect(try await NotificationLedgerModel.find(ids.ledger, on: db) == nil)
            #expect(try await ArcusNotificationOutboxModel.find(ids.outbox, on: db) == nil)
            #expect(try await NotificationDebugModel.find(ids.debug, on: db) == nil)
            #expect(try await NotificationSendAttemptModel.find(ids.attempt, on: db) == nil)
        }
    }

    @Test("non-CAP records persist without a series and never enter the NWS drain", arguments: ["spc-meso", "test-product"])
    func nonCAPIdentity(kind: String) async throws {
        try await withDatabase { db in
            let sql = try #require(db as? any SQLDatabase)
            let fixture = try await seed(on: db)
            try await ArcusNotificationOutboxModel.query(on: db).set(\.$state, to: "done").update()
            let subject = NotificationSubject(kind: try #require(.init(rawValue: kind)), productID: "product:2026:1234", revisionID: "initial")
            let ids = try await records(series: nil, installation: fixture.installation,
                                        revision: subject.revisionID, subject: subject, on: db)
            try await expectSubjects(ids, equal: subject, on: db)
            #expect(try await NotificationLedgerModel.find(ids.ledger, on: db)?.$series.id == nil)
            // Same installation/product/revision conflicts even with a different mode.
            let duplicateLedger = try await sql.raw("""
                INSERT INTO notification_ledger
                (id, installation_id, revision_urn, mode, reason, freshness_state, subject_kind, subject_id, subject_revision_id)
                VALUES (\(bind: UUID()), \(bind: fixture.installation), 'initial', 'ugc', 'new', 'fresh', \(bind: kind), \(bind: subject.productID), 'initial')
                ON CONFLICT DO NOTHING RETURNING id;
                """).first()
            #expect(duplicateLedger == nil)
            let duplicateOutbox = try await sql.raw("""
                INSERT INTO notification_outbox
                (id, revision_urn, mode, reason, state, attempts, available_at, subject_kind, subject_id, subject_revision_id)
                VALUES (\(bind: UUID()), 'initial', 'h3', 'new', 'ready', 0, \(bind: now), \(bind: kind), \(bind: subject.productID), 'initial')
                ON CONFLICT DO NOTHING RETURNING id;
                """).first()
            #expect(duplicateOutbox == nil)
            let nws = try await records(series: fixture.series, installation: fixture.installation,
                                        revision: "urn:oid:\(UUID())", on: db)
            let claims = try await NotificationDispatchOutboxStore().claim(mode: "h3", limit: 10, now: now, on: db)
            #expect(claims.map(\.id) == [nws.outbox])
            #expect(try await ArcusNotificationOutboxModel.find(ids.outbox, on: db)?.state == "ready")
        }
    }

    @Test("dashboard debug query retains a meso preview without an NWS series")
    func dashboardDebugQueryIncludesSerieslessMesoPreview() async throws {
        try await withDatabase { db in
            let sql = try #require(db as? any SQLDatabase)
            let subject = NotificationSubject.spcMeso(issueYear: 2026, number: 90_000_000 + Int.random(in: 1...999_999))
            let debug = NotificationDebugModel(
                seriesID: nil,
                revisionUrn: subject.revisionID,
                mode: "h3",
                reason: "new",
                recordKind: .previewNoCandidates,
                title: "Mesoscale Discussion for your area",
                subtitle: "Watch potential not specified",
                body: "SPC is monitoring storms near your area.",
                subject: subject
            )
            try await debug.create(on: db)
            debug.created = Date(timeIntervalSinceNow: 60)
            try await debug.update(on: db)

            let entries = try await OperatorDashboardSnapshotRefresher()
                .loadRecentNotificationDebugEntries(on: sql)

            let entry = try #require(entries.first { $0.subjectID == subject.productID })
            #expect(entry.seriesID == nil)
            #expect(entry.subjectKind == "spc-meso")
            #expect(entry.eventName == "Mesoscale Discussion")
            #expect(entry.title == "Mesoscale Discussion for your area")
        }
    }

    @Test("incomplete, mismatched and conflicting identities are rejected in all four tables")
    func invalidIdentities() async throws {
        try await withDatabase { db in
            let sql = try #require(db as? any SQLDatabase)
            let fixture = try await seed(on: db)
            let subject = NotificationSubject(kind: .spcMeso, productID: "spc:md:2026:1234", revisionID: "initial")
            let ids = try await records(series: nil, installation: fixture.installation,
                                        revision: "initial", subject: subject, on: db)
            for (table, id) in [("notification_outbox", ids.outbox), ("notification_ledger", ids.ledger),
                                ("notification_debug", ids.debug), ("notification_send_attempts", ids.attempt)] {
                for blank in ["\u{00A0}", "\u{2007}", "\u{202F}", "\u{200B}"] {
                    for column in ["subject_kind", "subject_id"] {
                        try await expectRejected(on: db) {
                            try await sql.raw("UPDATE \(ident: table) SET \(ident: column) = \(bind: blank) WHERE id = \(bind: id)").run()
                        }
                    }
                    try await expectRejected(on: db) {
                        try await sql.raw("UPDATE \(ident: table) SET subject_revision_id = \(bind: blank), revision_urn = \(bind: blank) WHERE id = \(bind: id)").run()
                    }
                }
                for assignment in ["subject_kind = NULL", "subject_kind = ''", "subject_kind = E' \\t\\n'",
                                   "subject_id = NULL", "subject_id = ''", "subject_id = E' \\t\\n'",
                                   "subject_revision_id = NULL", "subject_revision_id = 'different'",
                                   "subject_revision_id = '', revision_urn = ''",
                                   "subject_revision_id = E' \\t\\n', revision_urn = E' \\t\\n'",
                                   "subject_kind = 'nws'",
                                   "subject_kind = NULL, subject_id = NULL, subject_revision_id = NULL"] {
                    try await expectRejected(on: db) {
                        try await sql.raw("UPDATE \(ident: table) SET \(unsafeRaw: assignment) WHERE id = \(bind: id)").run()
                    }
                }
                try await expectRejected(on: db) {
                    try await sql.raw("UPDATE \(ident: table) SET series_id = \(bind: fixture.series) WHERE id = \(bind: id)").run()
                }
            }
        }
    }

    @Test("extensibility migration upgrades existing data and rolls back atomically")
    func extensibilityMigration() async throws {
        try await withDatabase { db in
            let fixture = try await seed(on: db)
            let nws = try await records(series: fixture.series, installation: fixture.installation,
                                        revision: "nws-revision", on: db)
            let meso = NotificationSubject(kind: .spcMeso, productID: "meso", revisionID: "initial")
            let mesoIDs = try await records(series: nil, installation: fixture.installation,
                                            revision: "initial", subject: meso, on: db)
            try await MakeNotificationSubjectKindsExtensible().revert(on: db)
            let future = NotificationSubject(kind: try #require(.init(rawValue: "test-product")),
                                             productID: "future", revisionID: "initial")
            try await expectRejected(on: db) {
                _ = try await records(series: nil, installation: fixture.installation,
                                      revision: "initial", subject: future, on: db)
            }
            try await MakeNotificationSubjectKindsExtensible().prepare(on: db)
            try await expectSubjects(nws, equal: .nws(seriesID: fixture.series, revisionUrn: "nws-revision"), on: db)
            try await expectSubjects(mesoIDs, equal: meso, on: db)
            // Unknown data in the final table proves rollback cannot leave earlier
            // tables with restored closed constraints after a late validation failure.
            let attempt = NotificationSendAttemptModel(
                seriesID: nil, revisionUrn: "initial", mode: .h3, reason: .new, outcome: .noOp,
                candidateResolutionReached: false, candidateCount: 0, claimedCount: 0,
                sentCount: 0, failedCount: 0, subject: future
            )
            try await attempt.create(on: db)
            try await expectRejected(on: db) { try await MakeNotificationSubjectKindsExtensible().revert(on: db) }
            #expect(try await NotificationSendAttemptModel.find(attempt.requireID(), on: db)?.subject == future)
            let futureIDs = try await records(series: nil, installation: fixture.installation,
                                              revision: "initial", subject: future, on: db)
            try await expectSubjects(futureIDs, equal: future, on: db)
        }
    }

    @Test("rollback refuses non-CAP data without partially reverting earlier tables")
    func rollbackSafety() async throws {
        try await withDatabase { db in
            let fixture = try await seed(on: db)
            let subject = NotificationSubject(kind: .spcMeso, productID: "spc:md:2026:1234", revisionID: "initial")
            // Only the final table has non-CAP data, exercising late rollback failure.
            let attempt = NotificationSendAttemptModel(
                seriesID: nil, revisionUrn: "initial", mode: .h3, reason: .new, outcome: .noOp,
                candidateResolutionReached: false, candidateCount: 0, claimedCount: 0,
                sentCount: 0, failedCount: 0, subject: subject
            )
            try await attempt.create(on: db)
            try await expectRejected(on: db) { try await AddNotificationSubjectIdentity().revert(on: db) }
            #expect(try await NotificationSendAttemptModel.find(attempt.requireID(), on: db)?.subject == subject)
            let ids = try await records(series: nil, installation: fixture.installation,
                                        revision: "initial", subject: subject, on: db)
            try await expectSubjects(ids, equal: subject, on: db)
        }
    }
}
