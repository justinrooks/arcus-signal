@testable import App
import Fluent
import FluentPostgresDriver
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import ArcusCore

@Suite("Notification send job delivery boundary", .serialized)
struct NotificationSendJobDeliveryBoundaryTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            let databaseURL = Environment.get("DATABASE_URL")
                ?? "postgres://arcus:arcus@127.0.0.1:5432/arcus_signal?tlsmode=disable"
            app.databases.use(try .postgres(url: databaseURL), as: .psql)
            try await bootstrapTables(on: app.db)
            try await test(app)
        } catch {
            Issue.record("Test DB error: \(String(reflecting: error))")
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func bootstrapTables(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS device_installations (
                installation_id UUID PRIMARY KEY,
                apns_device_token TEXT NOT NULL,
                apns_environment TEXT NOT NULL,
                platform TEXT NOT NULL,
                os_version TEXT NOT NULL,
                app_version TEXT NOT NULL,
                build_number TEXT NOT NULL,
                location_auth TEXT NOT NULL,
                is_active BOOLEAN NOT NULL,
                is_subscribed BOOLEAN NOT NULL DEFAULT TRUE,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                last_seen_at TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            ALTER TABLE device_installations
            ADD COLUMN IF NOT EXISTS is_subscribed BOOLEAN NOT NULL DEFAULT TRUE;
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS arcus_series (
                id UUID PRIMARY KEY,
                source TEXT NOT NULL,
                event TEXT NOT NULL,
                source_url TEXT NOT NULL,
                current_revision_urn TEXT NOT NULL,
                current_revision_sent TIMESTAMP NOT NULL,
                message_type TEXT NOT NULL,
                content_fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                severity TEXT NOT NULL,
                urgency TEXT NOT NULL,
                certainty TEXT NOT NULL,
                ugc_codes TEXT[] NOT NULL,
                created TIMESTAMP NOT NULL,
                updated TIMESTAMP NOT NULL,
                last_seen_active TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            ALTER TABLE arcus_series
              ADD COLUMN IF NOT EXISTS sent TIMESTAMP,
              ADD COLUMN IF NOT EXISTS effective TIMESTAMP,
              ADD COLUMN IF NOT EXISTS onset TIMESTAMP,
              ADD COLUMN IF NOT EXISTS expires TIMESTAMP,
              ADD COLUMN IF NOT EXISTS ends TIMESTAMP,
              ADD COLUMN IF NOT EXISTS geometry JSONB,
              ADD COLUMN IF NOT EXISTS title TEXT,
              ADD COLUMN IF NOT EXISTS area_desc TEXT,
              ADD COLUMN IF NOT EXISTS category TEXT,
              ADD COLUMN IF NOT EXISTS sender_name TEXT,
              ADD COLUMN IF NOT EXISTS headline TEXT,
              ADD COLUMN IF NOT EXISTS description TEXT,
              ADD COLUMN IF NOT EXISTS instructions TEXT,
              ADD COLUMN IF NOT EXISTS response TEXT,
              ADD COLUMN IF NOT EXISTS status TEXT,
              ADD COLUMN IF NOT EXISTS tornado_detection TEXT,
              ADD COLUMN IF NOT EXISTS tornado_damage_threat TEXT,
              ADD COLUMN IF NOT EXISTS max_wind_gust TEXT,
              ADD COLUMN IF NOT EXISTS max_hail_size TEXT,
              ADD COLUMN IF NOT EXISTS wind_threat TEXT,
              ADD COLUMN IF NOT EXISTS hail_threat TEXT,
              ADD COLUMN IF NOT EXISTS thunderstorm_damage_threat TEXT,
              ADD COLUMN IF NOT EXISTS flash_flood_detection TEXT,
              ADD COLUMN IF NOT EXISTS flash_flood_damage_threat TEXT;
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS alert_revisions (
                id UUID PRIMARY KEY,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                message_type TEXT NOT NULL,
                sent TIMESTAMP NOT NULL,
                received TIMESTAMP NOT NULL,
                referenced_urns TEXT[] NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS arcus_geolocation (
                id UUID PRIMARY KEY,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                geometry JSONB NOT NULL,
                geometry_hash TEXT NOT NULL,
                h3_cells BIGINT[] NOT NULL,
                h3_resolution SMALLINT NOT NULL,
                h3_hash TEXT NOT NULL,
                created TIMESTAMP NOT NULL,
                updated TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_ledger (
                id UUID PRIMARY KEY,
                installation_id UUID NOT NULL REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                freshness_state TEXT NOT NULL,
                status TEXT,
                apns_error_code TEXT,
                completed_at TIMESTAMP,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_ledger_identity
            ON notification_ledger (installation_id, series_id, revision_urn);
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_missed_decisions (
                id UUID PRIMARY KEY,
                installation_id UUID NOT NULL REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                freshness_state TEXT NOT NULL,
                miss_reason TEXT NOT NULL,
                permission_mode TEXT NOT NULL,
                captured_at TIMESTAMP NOT NULL,
                received_at TIMESTAMP NOT NULL,
                evaluated_at TIMESTAMP NOT NULL,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE UNIQUE INDEX IF NOT EXISTS idx_notification_missed_decisions_identity
            ON notification_missed_decisions
            (installation_id, series_id, revision_urn, mode, reason, miss_reason);
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_debug (
                id UUID PRIMARY KEY,
                series_id UUID NOT NULL,
                installation_id UUID NULL,
                notification_ledger_id UUID NULL,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                record_kind TEXT NOT NULL,
                title TEXT NOT NULL,
                subtitle TEXT NOT NULL,
                body TEXT NOT NULL,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            CREATE TABLE IF NOT EXISTS notification_send_attempts (
                id UUID PRIMARY KEY,
                series_id UUID NOT NULL REFERENCES arcus_series(id) ON DELETE CASCADE,
                revision_urn TEXT NOT NULL,
                mode TEXT NOT NULL,
                reason TEXT NOT NULL,
                outcome TEXT NOT NULL,
                no_op_reason TEXT,
                candidate_resolution_reached BOOLEAN NOT NULL,
                candidate_count INTEGER NOT NULL,
                claimed_count INTEGER NOT NULL,
                sent_count INTEGER NOT NULL,
                failed_count INTEGER NOT NULL,
                attempted_at TIMESTAMP NOT NULL
            );
            """).run()
    }

    private func makeQueueContext(app: Application) -> QueueContext {
        QueueContext(
            queueName: QueueName(string: "test-send"),
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    private func seedInstallation(id: UUID, locationAuth: LocationAuth, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, apns_device_token, apns_environment, platform, os_version, app_version,
                 build_number, location_auth, is_active, is_subscribed, created_at, updated_at, last_seen_at)
            VALUES
                (\(bind: id), 'token', 'sandbox', 'iOS', '26.0', '1.0.0', '100',
                 \(bind: locationAuth.rawValue), TRUE, TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (installation_id) DO UPDATE
            SET location_auth = EXCLUDED.location_auth
            """).run()
    }

    private func seedSeries(
        id: UUID,
        revisionUrn: String,
        state: String = EventState.active.rawValue,
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO arcus_series
                (id, source, event, source_url, current_revision_urn, current_revision_sent, message_type,
                 content_fingerprint, state, severity, urgency, certainty, ugc_codes, created, updated, last_seen_active)
            VALUES
                (\(bind: id), 'nws', 'Tornado Warning', 'https://api.weather.gov/alerts/test', \(bind: revisionUrn),
                 NOW(), 'alert', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                 \(bind: state), 'severe', 'immediate', 'observed', ARRAY[]::text[], NOW(), NOW(), NOW())
            ON CONFLICT (id) DO UPDATE
            SET current_revision_urn = EXCLUDED.current_revision_urn,
                state = EXCLUDED.state
            """).run()
    }

    private func seedRevision(seriesID: UUID, revisionUrn: String, on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO alert_revisions
                (id, series_id, revision_urn, message_type, sent, received, referenced_urns)
            VALUES
                (\(bind: UUID()), \(bind: seriesID), \(bind: revisionUrn), 'alert', NOW(), NOW(), ARRAY[]::text[])
            """).run()
    }

    private func makeSeries(id: UUID, revisionUrn: String, now: Date) -> ArcusSeriesModel {
        ArcusSeriesModel(
            id: id,
            source: "nws",
            event: "Tornado Warning",
            sourceURL: "https://api.weather.gov/alerts/test",
            currentRevisionUrn: revisionUrn,
            currentRevisionSent: now,
            messageType: "alert",
            contentFingerprint: String(repeating: "a", count: 64),
            state: "active",
            lastSeenActive: now,
            severity: "severe",
            urgency: "immediate",
            certainty: "observed",
            ugcCodes: []
        )
    }

    private func makeCandidate(
        id: UUID,
        auth: LocationAuth,
        capturedAt: Date
    ) -> NotificationCandidate {
        NotificationCandidate(
            id: id,
            apnsToken: "token",
            apnsEnvironment: "sandbox",
            locationAuthRaw: auth.rawValue,
            capturedAt: capturedAt,
            receivedAt: capturedAt.addingTimeInterval(30),
            countyLabel: "Test County",
            fireZoneLabel: nil
        )
    }

    @Test("stale candidates are blocked before ledger and persist one stale miss across retries")
    func staleCandidatesBlockedBeforeLedgerAndIdempotent() async throws {
        try await withApp { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)

            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:stale-boundary"
            let now = Date()
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .whenInUse,
                capturedAt: now.addingTimeInterval(-(25 * 60 * 60))
            )

            try await seedInstallation(id: installationID, locationAuth: .whenInUse, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            _ = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: context
            )
            _ = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: context
            )

            let ledgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            #expect(ledgerCount == 0)

            let missedRows = try await NotificationMissedDecisionModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .all()
            #expect(missedRows.count == 1)
            #expect(missedRows.first?.freshnessState == .stale)

            let sends = await sender.sendCount
            #expect(sends == 0)
        }
    }

    @Test("degraded candidates remain eligible and persist degraded ledger freshness")
    func degradedCandidatesRemainEligibleAndPersistLedgerFreshness() async throws {
        try await withApp { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)

            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:degraded-boundary"
            let now = Date()
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .whenInUse,
                capturedAt: now.addingTimeInterval(-(3 * 60 * 60))
            )

            try await seedInstallation(id: installationID, locationAuth: .whenInUse, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let summary = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: context
            )

            #expect(summary.claimedCount == 1)
            #expect(summary.sentCount == 1)
            #expect(summary.staleMissedCount == 0)

            let ledger = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .first()
            #expect(ledger != nil)
            #expect(ledger?.freshnessState == .degraded)
        }
    }

    @Test("fresh candidates persist fresh ledger freshness")
    func freshCandidatesPersistFreshLedgerFreshness() async throws {
        try await withApp { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)

            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:fresh-boundary"
            let now = Date()
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: now.addingTimeInterval(-(60 * 60))
            )

            try await seedInstallation(id: installationID, locationAuth: .always, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let summary = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .ugc, reason: .new),
                and: series,
                using: context
            )

            #expect(summary.claimedCount == 1)
            #expect(summary.sentCount == 1)
            #expect(summary.staleMissedCount == 0)

            let ledger = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .first()
            #expect(ledger != nil)
            #expect(ledger?.freshnessState == .fresh)
        }
    }

    @Test("dequeue persists inactive series no-op without resolving candidates or sending")
    func dequeuePersistsInactiveSeriesNoOpWithoutResolvingCandidatesOrSending() async throws {
        try await withApp { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let seriesID = UUID()
            let revisionUrn = "urn:oid:inactive-dequeue-\(UUID().uuidString.lowercased())"
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )

            try await seedSeries(
                id: seriesID,
                revisionUrn: revisionUrn,
                state: EventState.expired.rawValue,
                on: app.db
            )
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)

            try await job.dequeue(context, payload)

            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .all()
            #expect(attempts.count == 1)

            let attempt = try #require(attempts.first)
            #expect(attempt.outcome == NotificationSendAttemptOutcome.noOp.rawValue)
            #expect(attempt.noOpReason == NotificationSendNoOpReason.inactiveOrExpiredSeries.rawValue)
            #expect(attempt.mode == NotificationTargetMode.h3.rawValue)
            #expect(attempt.reason == NotificationReason.new.rawValue)
            #expect(attempt.candidateResolutionReached == false)
            #expect(attempt.candidateCount == 0)
            #expect(attempt.claimedCount == 0)
            #expect(attempt.sentCount == 0)
            #expect(attempt.failedCount == 0)
            #expect(await sender.sendCount == 0)
        }
    }
}

private actor RecordingNotificationSender: NotificationSender {
    private(set) var sendCount = 0

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        sendCount += 1
    }
}
