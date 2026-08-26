@testable import App
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import ArcusCore

@Suite("Notification send job delivery boundary", .serialized)
struct NotificationSendJobDeliveryBoundaryTests {
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
            CREATE TABLE IF NOT EXISTS device_presence (
                installation_id UUID PRIMARY KEY REFERENCES device_installations(installation_id) ON DELETE CASCADE,
                captured_at TIMESTAMP NOT NULL,
                received_at TIMESTAMP NOT NULL,
                location_age_seconds DOUBLE PRECISION NOT NULL,
                horizontal_accuracy_meters DOUBLE PRECISION NOT NULL,
                cell_scheme TEXT NOT NULL,
                h3_cell BIGINT,
                h3_resolution INTEGER,
                county TEXT,
                zone TEXT,
                fire_zone TEXT,
                source TEXT NOT NULL,
                created_at TIMESTAMP NOT NULL,
                updated_at TIMESTAMP NOT NULL,
                county_label TEXT,
                fire_zone_label TEXT
            );
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

    private func makeUniqueH3Cell() -> Int64 {
        Int64(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
            radix: 16
        )!
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

    private func seedH3Presence(
        installationID: UUID,
        h3Cell: Int64,
        capturedAt: Date,
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_presence
                (installation_id, captured_at, received_at, location_age_seconds, horizontal_accuracy_meters,
                 cell_scheme, h3_cell, h3_resolution, county, zone, fire_zone, source, created_at, updated_at,
                 county_label, fire_zone_label)
            VALUES
                (\(bind: installationID), \(bind: capturedAt), \(bind: capturedAt), 0, 0, 'h3',
                 \(bind: h3Cell), 8, NULL, NULL, NULL, 'foreground', NOW(), NOW(), 'Test County', NULL)
            """).run()
    }

    private func seedH3Candidate(
        installationID: UUID,
        h3Cell: Int64,
        capturedAt: Date,
        on db: any Database
    ) async throws {
        try await seedInstallation(id: installationID, locationAuth: .always, on: db)
        try await seedH3Presence(
            installationID: installationID,
            h3Cell: h3Cell,
            capturedAt: capturedAt,
            on: db
        )
    }

    private func seedGeolocation(seriesID: UUID, h3Cell: Int64, on db: any Database) async throws {
        try await ArcusGeolocationModel(
            series: seriesID,
            geometry: .point(lon: 0, lat: 0),
            geometryHash: String(repeating: "a", count: 64),
            h3Cells: [h3Cell],
            h3Resolution: 8,
            h3Hash: String(repeating: "b", count: 64)
        ).create(on: db)
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

    @Test("legacy payloads decode without an installation constraint")
    func legacyPayloadDecodesWithoutInstallationConstraint() throws {
        let seriesID = UUID()
        let data = Data("""
            {
              "seriesId": "\(seriesID.uuidString)",
              "revisionUrn": "urn:oid:legacy",
              "mode": "h3",
              "reason": "new"
            }
            """.utf8)

        let payload = try JSONDecoder().decode(NotificationSendJobPayload.self, from: data)

        #expect(payload.seriesId == seriesID)
        #expect(payload.installationId == nil)
    }

    @Test("stale candidates are blocked before ledger and persist one stale miss across retries")
    func staleCandidatesBlockedBeforeLedgerAndIdempotent() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
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
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
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
            #expect(ledger?.status == "sent")
            #expect(ledger?.completedAt != nil)
        }
    }

    @Test("fresh candidates persist fresh ledger freshness")
    func freshCandidatesPersistFreshLedgerFreshness() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
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
            #expect(ledger?.status == "sent")
            #expect(ledger?.completedAt != nil)
        }
    }

    @Test("duplicate claims skip all downstream delivery side effects")
    func duplicateClaimsSkipDownstreamDeliverySideEffects() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)

            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:duplicate-boundary"
            let now = Date()
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: now.addingTimeInterval(-(60 * 60))
            )
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                installationId: installationID
            )

            try await seedInstallation(id: installationID, locationAuth: .always, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let first = try await job.dispatchNotifications(
                to: [candidate],
                with: payload,
                and: series,
                using: context
            )
            let duplicate = try await job.dispatchNotifications(
                to: [candidate],
                with: payload,
                and: series,
                using: context
            )

            #expect(first.claimedCount == 1)
            #expect(first.sentCount == 1)
            #expect(duplicate.claimedCount == 0)
            #expect(duplicate.sentCount == 0)
            #expect(duplicate.failedCount == 0)
            #expect(duplicate.noOpReason == .allCandidatesPreviouslyClaimed)
            #expect(await sender.sendCount == 1)

            let debugCount = try await NotificationDebugModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$installationID == installationID)
                .filter(\.$revisionUrn == revisionUrn)
                .filter(\.$recordKind == NotificationDebugRecordKind.candidate.rawValue)
                .count()
            #expect(debugCount == 1)
        }
    }

    @Test("constrained and unconstrained dequeue attempts converge on one claim")
    func concurrentConstrainedAndUnconstrainedAttemptsConvergeOnOneClaim() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let sender = GatedRecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let constrainedContext = makeQueueContext(app: app)
            let unconstrainedContext = makeQueueContext(app: app)
            let seriesID = UUID()
            let revisionUrn = "urn:oid:concurrent-constraint-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let installationID = UUID()
            let otherInstallationID = UUID()

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: installationID,
                h3Cell: h3Cell,
                capturedAt: Date(),
                on: app.db
            )
            try await seedH3Candidate(
                installationID: otherInstallationID,
                h3Cell: h3Cell,
                capturedAt: Date(),
                on: app.db
            )

            async let constrained: Void = job.dequeue(
                constrainedContext,
                .init(
                    seriesId: seriesID,
                    revisionUrn: revisionUrn,
                    mode: .h3,
                    reason: .new,
                    installationId: installationID
                )
            )
            await sender.waitForFirstSend()

            async let unconstrained: Void = job.dequeue(
                unconstrainedContext,
                .init(
                    seriesId: seriesID,
                    revisionUrn: revisionUrn,
                    mode: .h3,
                    reason: .new
                )
            )
            await sender.waitForSendCount(2)
            await sender.releaseFirstSend()
            _ = try await (constrained, unconstrained)

            let ledgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            let otherLedgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == otherInstallationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .all()

            #expect(ledgerCount == 1)
            #expect(otherLedgerCount == 1)
            #expect(attempts.count == 2)
            let constrainedAttempt = try #require(attempts.first { $0.candidateCount == 1 })
            let unconstrainedAttempt = try #require(attempts.first { $0.candidateCount == 2 })
            #expect(constrainedAttempt.claimedCount == 1)
            #expect(unconstrainedAttempt.claimedCount == 1)
            #expect(unconstrainedAttempt.sentCount == 1)
            #expect(attempts.reduce(0) { $0 + $1.claimedCount } == 2)
            #expect(attempts.reduce(0) { $0 + $1.sentCount } == 2)
            #expect(await sender.sendCount == 2)
        }
    }

    @Test("generic sender failure persists one failed claimed delivery")
    func genericSenderFailurePersistsFailedClaim() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let job = NotificationSendJob(sender: ThrowingNotificationSender())
            let context = makeQueueContext(app: app)

            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:failed-boundary"
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
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: context
            )

            #expect(summary.claimedCount == 1)
            #expect(summary.sentCount == 0)
            #expect(summary.failedCount == 1)
            #expect(summary.noOpReason == nil)

            let ledger = try #require(try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .first())
            #expect(ledger.status == "failed")
            #expect(ledger.completedAt != nil)
            #expect(ledger.apnsErrorCode == nil)
        }
    }

    @Test("dequeue persists inactive series no-op without resolving candidates or sending")
    func dequeuePersistsInactiveSeriesNoOpWithoutResolvingCandidatesOrSending() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
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

    @Test("dequeue persists stale revision mismatch without resolving candidates or sending")
    func dequeuePersistsStaleRevisionMismatchWithoutResolvingCandidatesOrSending() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let seriesID = UUID()
            let currentRevisionUrn = "urn:oid:current-dequeue-\(UUID().uuidString.lowercased())"
            let staleRevisionUrn = "urn:oid:stale-dequeue-\(UUID().uuidString.lowercased())"
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: staleRevisionUrn,
                mode: .h3,
                reason: .update
            )

            try await seedSeries(id: seriesID, revisionUrn: currentRevisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: currentRevisionUrn, on: app.db)

            try await job.dequeue(context, payload)

            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == staleRevisionUrn)
                .all()
            let ledgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == staleRevisionUrn)
                .count()
            #expect(attempts.count == 1)
            #expect(ledgerCount == 0)

            let attempt = try #require(attempts.first)
            #expect(attempt.outcome == NotificationSendAttemptOutcome.noOp.rawValue)
            #expect(attempt.noOpReason == NotificationSendNoOpReason.staleRevisionMismatch.rawValue)
            #expect(attempt.mode == NotificationTargetMode.h3.rawValue)
            #expect(attempt.reason == NotificationReason.update.rawValue)
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

private actor GatedRecordingNotificationSender: NotificationSender {
    private(set) var sendCount = 0
    private var firstSendStarted = false
    private var firstSendStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var sendCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var firstSendRelease: CheckedContinuation<Void, Never>?

    func waitForFirstSend() async {
        guard !firstSendStarted else { return }

        await withCheckedContinuation { continuation in
            firstSendStartedWaiters.append(continuation)
        }
    }

    func waitForSendCount(_ expectedCount: Int) async {
        guard sendCount < expectedCount else { return }

        await withCheckedContinuation { continuation in
            sendCountWaiters.append((expectedCount, continuation))
        }
    }

    func releaseFirstSend() {
        firstSendRelease?.resume()
        firstSendRelease = nil
    }

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        sendCount += 1

        if sendCount == 1 {
            firstSendStarted = true
            let waiters = firstSendStartedWaiters
            firstSendStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        let readyWaiters = sendCountWaiters.filter { $0.count <= sendCount }
        sendCountWaiters.removeAll { $0.count <= sendCount }
        readyWaiters.forEach { $0.continuation.resume() }

        if sendCount == 1 {
            await withCheckedContinuation { continuation in
                firstSendRelease = continuation
            }
        }
    }
}

private struct ThrowingNotificationSender: NotificationSender {
    private struct DeterministicFailure: Error {}

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        throw DeterministicFailure()
    }
}
