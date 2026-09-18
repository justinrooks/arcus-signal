@testable import App
import APNSCore
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues
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
                retry_owner_id TEXT,
                retry_generation INTEGER NOT NULL DEFAULT 0,
                completed_at TIMESTAMP,
                created TIMESTAMP NOT NULL
            );
            """).run()

        try await sql.raw("""
            ALTER TABLE notification_ledger
              ADD COLUMN IF NOT EXISTS retry_owner_id TEXT,
              ADD COLUMN IF NOT EXISTS retry_generation INTEGER NOT NULL DEFAULT 0;
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

    private func makeQueueContext(app: Application, jobID: JobIdentifier? = nil) -> QueueContext {
        var logger = app.logger
        if let jobID {
            logger[metadataKey: "job_id"] = .string(jobID.string)
        }
        return QueueContext(
            queueName: QueueName(string: "test-send"),
            configuration: app.queues.configuration,
            application: app,
            logger: logger,
            on: app.eventLoopGroup.any()
        )
    }

    private func makeUniqueH3Cell() -> Int64 {
        Int64(
            UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(15),
            radix: 16
        )!
    }

    private func seedInstallation(
        id: UUID,
        locationAuth: LocationAuth,
        apnsToken: String = "token",
        on db: any Database
    ) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("""
            INSERT INTO device_installations
                (installation_id, apns_device_token, apns_environment, platform, os_version, app_version,
                 build_number, location_auth, is_active, is_subscribed, created_at, updated_at, last_seen_at)
            VALUES
                (\(bind: id), \(bind: apnsToken), 'sandbox', 'iOS', '26.0', '1.0.0', '100',
                 \(bind: locationAuth.rawValue), TRUE, TRUE, NOW(), NOW(), NOW())
            ON CONFLICT (installation_id) DO UPDATE
            SET location_auth = EXCLUDED.location_auth,
                apns_device_token = EXCLUDED.apns_device_token,
                is_active = TRUE,
                is_subscribed = TRUE
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
        apnsToken: String = "token",
        on db: any Database
    ) async throws {
        try await seedInstallation(
            id: installationID,
            locationAuth: .always,
            apnsToken: apnsToken,
            on: db
        )
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
        capturedAt: Date,
        apnsToken: String = "token"
    ) -> NotificationCandidate {
        NotificationCandidate(
            id: id,
            apnsToken: apnsToken,
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
        #expect(payload.deliveryAttemptId == nil)
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

    @Test("unknown transport failure persists one retrying claimed delivery")
    func transportFailurePersistsRetryingClaim() async throws {
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
            #expect(summary.failedCount == 0)
            #expect(summary.retryableFailureCount == 1)
            #expect(summary.noOpReason == nil)

            let ledger = try #require(try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == installationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .first())
            #expect(ledger.status == "retrying")
            #expect(ledger.completedAt == nil)
            #expect(ledger.apnsErrorCode == APNsDeliveryFailureClassifier.transportErrorCode)
        }
    }

    @Test("transient failure retries the same ledger row and later succeeds")
    func transientFailureRetriesSameLedgerRow() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let token = "retry-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.transportFailure, .success]
            ])
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:retry-success-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: installationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: token,
                on: app.db
            )

            do {
                try await job.dequeue(context, payload)
                Issue.record("Expected the transient failure to request a queue retry")
            } catch is NotificationDeliveryRetryableError {
                // Expected.
            }

            let retrying = try #require(
                try await NotificationLedgerModel.query(on: app.db)
                    .filter(\.$deviceInstallation.$id == installationID)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            let ledgerID = try #require(retrying.id)
            #expect(retrying.status == "retrying")
            #expect(retrying.completedAt == nil)

            try await job.dequeue(context, payload)

            let sent = try #require(try await NotificationLedgerModel.find(ledgerID, on: app.db))
            let attempts = try await NotificationSendAttemptModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .sort(\.$attemptedAt, .ascending)
                .all()
            #expect(sent.status == "sent")
            #expect(sent.completedAt != nil)
            #expect(sent.apnsErrorCode == nil)
            #expect(attempts.map(\.outcome) == [
                NotificationSendAttemptOutcome.retrying.rawValue,
                NotificationSendAttemptOutcome.delivered.rawValue
            ])
            #expect(await sender.sentTokens == [token, token])
        }
    }

    @Test("a distinct job cannot consume another job's retrying delivery")
    func distinctJobCannotConsumeOwnedRetryingDelivery() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let token = "owned-retry-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.transportFailure, .success]
            ])
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:owned-retry-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let originalPayload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )
            let duplicatePayload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: installationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: token,
                on: app.db
            )

            do {
                try await job.dequeue(context, originalPayload)
                Issue.record("Expected the transient failure to request a queue retry")
            } catch is NotificationDeliveryRetryableError {
                // Expected.
            }

            try await job.dequeue(context, duplicatePayload)
            #expect(await sender.sentTokens == [token])

            try await job.dequeue(context, originalPayload)
            #expect(await sender.sentTokens == [token, token])
        }
    }

    @Test("a queue retry with no owned delivery does not discover new candidates")
    func preClaimQueueRetryDoesNotDiscoverCandidates() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in
                app.queues.use(.test)
                try await bootstrapTables(on: app.db)
            }
        ) { app in
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:preclaim-retry-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )
            let jobID = JobIdentifier()

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: installationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                on: app.db
            )

            app.queues.test.jobs[jobID] = JobData(
                payload: Array(try JSONEncoder().encode(payload)),
                maxRetryCount: NotificationSendJob.maximumRetryCount,
                jobName: NotificationSendJob.name,
                delayUntil: nil,
                queuedAt: .now,
                attempts: 1
            )

            try await job.dequeue(makeQueueContext(app: app, jobID: jobID), payload)

            let ledgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            #expect(ledgerCount == 0)
            #expect(await sender.sendCount == 0)
        }
    }

    @Test("retry sends only prior retrying deliveries and excludes newly eligible installations")
    func retryExcludesNewlyEligibleInstallations() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let retryToken = "prior-retrying-token"
            let newToken = "newly-eligible-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                retryToken: [.transportFailure, .success],
                newToken: [.success]
            ])
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let seriesID = UUID()
            let revisionUrn = "urn:oid:retry-scope-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let retryingInstallationID = UUID()
            let newlyEligibleInstallationID = UUID()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: retryingInstallationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: retryToken,
                on: app.db
            )

            do {
                try await job.dequeue(context, payload)
                Issue.record("Expected the transient failure to request a queue retry")
            } catch is NotificationDeliveryRetryableError {
                // Expected.
            }

            try await seedH3Candidate(
                installationID: newlyEligibleInstallationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: newToken,
                on: app.db
            )
            try await job.dequeue(context, payload)

            let newLedgerCount = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$deviceInstallation.$id == newlyEligibleInstallationID)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .count()
            #expect(newLedgerCount == 0)
            #expect(await sender.sentTokens == [retryToken, retryToken])
        }
    }

    @Test("mixed success and retryable failure records retry telemetry without resending success")
    func mixedSuccessAndRetryableFailureTelemetry() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let sentToken = "mixed-sent-token"
            let retryToken = "mixed-retry-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                sentToken: [.success],
                retryToken: [.transportFailure, .success]
            ])
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let seriesID = UUID()
            let revisionUrn = "urn:oid:mixed-retry-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: UUID(),
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: sentToken,
                on: app.db
            )
            try await seedH3Candidate(
                installationID: UUID(),
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: retryToken,
                on: app.db
            )

            do {
                try await job.dequeue(context, payload)
                Issue.record("Expected the retryable member of the batch to request a queue retry")
            } catch is NotificationDeliveryRetryableError {
                // Expected.
            }

            let firstAttempt = try #require(
                try await NotificationSendAttemptModel.query(on: app.db)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            #expect(firstAttempt.outcome == NotificationSendAttemptOutcome.retrying.rawValue)
            #expect(firstAttempt.sentCount == 1)
            #expect(firstAttempt.failedCount == 0)

            try await job.dequeue(context, payload)

            let sentTokens = await sender.sentTokens
            #expect(sentTokens.filter { $0 == sentToken }.count == 1)
            #expect(sentTokens.filter { $0 == retryToken }.count == 2)
        }
    }

    @Test("ledger completion failure after an APNs success is not classified or resent")
    func sentCompletionFailureDoesNotRetryAPNsDelivery() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let sender = RecordingNotificationSender()
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:sent-completion-failure-\(UUID().uuidString.lowercased())"
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new
            )
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: .now
            )

            try await seedInstallation(id: installationID, locationAuth: .always, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await sql.raw("DROP TRIGGER IF EXISTS test_reject_notification_sent ON notification_ledger").run()
            try await sql.raw("DROP FUNCTION IF EXISTS test_reject_notification_sent()").run()
            try await sql.raw("""
                CREATE FUNCTION test_reject_notification_sent() RETURNS trigger AS $$
                BEGIN
                    IF NEW.status = 'sent' THEN
                        RAISE EXCEPTION 'injected sent completion failure';
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_reject_notification_sent
                BEFORE UPDATE ON notification_ledger
                FOR EACH ROW EXECUTE FUNCTION test_reject_notification_sent();
                """).run()

            var completionFailed = false
            do {
                _ = try await job.dispatchNotifications(
                    to: [candidate],
                    with: payload,
                    and: series,
                    using: context
                )
            } catch {
                completionFailed = true
            }

            try await sql.raw("DROP TRIGGER IF EXISTS test_reject_notification_sent ON notification_ledger").run()
            try await sql.raw("DROP FUNCTION IF EXISTS test_reject_notification_sent()").run()

            #expect(completionFailed)
            let ledger = try #require(
                try await NotificationLedgerModel.query(on: app.db)
                    .filter(\.$deviceInstallation.$id == installationID)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            #expect(ledger.status == "claimed")
            #expect(ledger.apnsErrorCode == nil)

            let secondSummary = try await job.dispatchNotifications(
                to: [candidate],
                with: payload,
                and: series,
                using: context
            )
            #expect(secondSummary.claimedCount == 0)
            #expect(await sender.sendCount == 1)
        }
    }

    @Test("terminal APNs request failure does not deactivate the installation")
    func terminalRequestFailureKeepsInstallationActive() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:terminal-request"
            let token = "terminal-request-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.apns(status: 400, reason: "PayloadTooLarge")]
            ])
            let job = NotificationSendJob(sender: sender)
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: .now,
                apnsToken: token
            )

            try await seedInstallation(
                id: installationID,
                locationAuth: .always,
                apnsToken: token,
                on: app.db
            )
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let summary = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: makeQueueContext(app: app)
            )

            let installation = try #require(
                try await DeviceInstallationModel.find(installationID, on: app.db)
            )
            #expect(summary.failedCount == 1)
            #expect(summary.retryableFailureCount == 0)
            #expect(installation.isActive)
        }
    }

    @Test("invalid token failure deactivates the matching installation without retry")
    func invalidTokenFailureDeactivatesMatchingInstallation() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:invalid-token"
            let token = "invalid-device-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.apns(status: 410, reason: "Unregistered")]
            ])
            let job = NotificationSendJob(sender: sender)
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: .now,
                apnsToken: token
            )

            try await seedInstallation(
                id: installationID,
                locationAuth: .always,
                apnsToken: token,
                on: app.db
            )
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let summary = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: makeQueueContext(app: app)
            )

            let installation = try #require(
                try await DeviceInstallationModel.find(installationID, on: app.db)
            )
            #expect(summary.failedCount == 1)
            #expect(summary.retryableFailureCount == 0)
            #expect(installation.isActive == false)
        }
    }

    @Test("invalid-token ledger failure and endpoint deactivation roll back together")
    func invalidTokenFailureIsAtomic() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            guard let sql = app.db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:invalid-token-atomic-\(UUID().uuidString.lowercased())"
            let token = "invalid-token-atomic"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.apns(status: 410, reason: "Unregistered")]
            ])
            let job = NotificationSendJob(sender: sender)
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: .now,
                apnsToken: token
            )

            try await seedInstallation(
                id: installationID,
                locationAuth: .always,
                apnsToken: token,
                on: app.db
            )
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await sql.raw("DROP TRIGGER IF EXISTS test_reject_token_deactivation ON device_installations").run()
            try await sql.raw("DROP FUNCTION IF EXISTS test_reject_token_deactivation()").run()
            try await sql.raw("""
                CREATE FUNCTION test_reject_token_deactivation() RETURNS trigger AS $$
                BEGIN
                    IF NEW.is_active = FALSE THEN
                        RAISE EXCEPTION 'injected token deactivation failure';
                    END IF;
                    RETURN NEW;
                END;
                $$ LANGUAGE plpgsql;
                """).run()
            try await sql.raw("""
                CREATE TRIGGER test_reject_token_deactivation
                BEFORE UPDATE ON device_installations
                FOR EACH ROW EXECUTE FUNCTION test_reject_token_deactivation();
                """).run()

            var atomicUpdateFailed = false
            do {
                _ = try await job.dispatchNotifications(
                    to: [candidate],
                    with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                    and: series,
                    using: makeQueueContext(app: app)
                )
            } catch {
                atomicUpdateFailed = true
            }

            try await sql.raw("DROP TRIGGER IF EXISTS test_reject_token_deactivation ON device_installations").run()
            try await sql.raw("DROP FUNCTION IF EXISTS test_reject_token_deactivation()").run()

            #expect(atomicUpdateFailed)
            let installation = try #require(
                try await DeviceInstallationModel.find(installationID, on: app.db)
            )
            let ledger = try #require(
                try await NotificationLedgerModel.query(on: app.db)
                    .filter(\.$deviceInstallation.$id == installationID)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            #expect(installation.isActive)
            #expect(ledger.status == "claimed")
            #expect(ledger.apnsErrorCode == nil)
        }
    }

    @Test("invalid token failure deactivates only the installation still holding that token")
    func invalidTokenFailureHonorsTokenRotation() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:token-rotation"
            let oldToken = "old-token"
            let replacementToken = "replacement-token"
            let sender = RotatingTokenFailureSender(
                installationID: installationID,
                replacementToken: replacementToken
            )
            let job = NotificationSendJob(sender: sender)
            let series = makeSeries(id: seriesID, revisionUrn: revisionUrn, now: .now)
            let candidate = makeCandidate(
                id: installationID,
                auth: .always,
                capturedAt: .now,
                apnsToken: oldToken
            )

            try await seedInstallation(
                id: installationID,
                locationAuth: .always,
                apnsToken: oldToken,
                on: app.db
            )
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            let summary = try await job.dispatchNotifications(
                to: [candidate],
                with: .init(seriesId: seriesID, revisionUrn: revisionUrn, mode: .h3, reason: .new),
                and: series,
                using: makeQueueContext(app: app)
            )

            let installation = try #require(
                try await DeviceInstallationModel.find(installationID, on: app.db)
            )
            let ledger = try #require(
                try await NotificationLedgerModel.query(on: app.db)
                    .filter(\.$deviceInstallation.$id == installationID)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            #expect(summary.failedCount == 1)
            #expect(ledger.status == "failed")
            #expect(ledger.apnsErrorCode == "Unregistered")
            #expect(installation.apnsDeviceToken == replacementToken)
            #expect(installation.isActive)
        }
    }

    @Test("retrying delivery that becomes unsubscribed is terminalized without another send")
    func retryingDeliveryBecomesIneligible() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let token = "ineligible-retry-token"
            let sender = ScriptedNotificationSender(outcomesByToken: [
                token: [.transportFailure, .success]
            ])
            let job = NotificationSendJob(sender: sender)
            let context = makeQueueContext(app: app)
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:retry-ineligible-\(UUID().uuidString.lowercased())"
            let h3Cell = makeUniqueH3Cell()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                installationId: installationID
            )

            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedRevision(seriesID: seriesID, revisionUrn: revisionUrn, on: app.db)
            try await seedGeolocation(seriesID: seriesID, h3Cell: h3Cell, on: app.db)
            try await seedH3Candidate(
                installationID: installationID,
                h3Cell: h3Cell,
                capturedAt: .now,
                apnsToken: token,
                on: app.db
            )

            do {
                try await job.dequeue(context, payload)
                Issue.record("Expected the transient failure to request a queue retry")
            } catch is NotificationDeliveryRetryableError {
                // Expected.
            }

            let installation = try #require(
                try await DeviceInstallationModel.find(installationID, on: app.db)
            )
            installation.isSubscribed = false
            try await installation.update(on: app.db)

            try await job.dequeue(context, payload)

            let ledger = try #require(
                try await NotificationLedgerModel.query(on: app.db)
                    .filter(\.$deviceInstallation.$id == installationID)
                    .filter(\.$series.$id == seriesID)
                    .filter(\.$revisionUrn == revisionUrn)
                    .first()
            )
            #expect(ledger.status == "failed")
            #expect(ledger.apnsErrorCode == "RetryIneligibleCandidate")
            #expect(await sender.sentTokens == [token])
        }
    }

    @Test("concurrent retry reclaim has one database winner")
    func concurrentRetryReclaimHasOneWinner() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let store = NotificationDeliveryStore()
            let installationID = UUID()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:concurrent-retry-reclaim"
            let retryOwnerID = UUID().uuidString
            try await seedInstallation(id: installationID, locationAuth: .always, on: app.db)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)
            let claim = try await store.claim(
                installationID: installationID,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                freshnessState: .fresh,
                retryOwnerID: retryOwnerID,
                on: app.db
            )
            try await store.markRetrying(
                claimID: claim.id,
                retryOwnerID: retryOwnerID,
                retryGeneration: claim.retryGeneration,
                apnsErrorCode: APNsDeliveryFailureClassifier.transportErrorCode,
                on: app.db
            )
            let delivery = try #require(
                try await store.loadRetryingDeliveries(
                    seriesID: seriesID,
                    revisionUrn: revisionUrn,
                    installationID: installationID,
                    retryOwnerID: retryOwnerID,
                    on: app.db
                ).first
            )

            async let first = store.reclaimRetrying(
                delivery,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                retryOwnerID: retryOwnerID,
                freshnessState: .fresh,
                on: app.db
            )
            async let second = store.reclaimRetrying(
                delivery,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                retryOwnerID: retryOwnerID,
                freshnessState: .fresh,
                on: app.db
            )
            let results = try await [first, second]

            #expect(results.filter(\.inserted).count == 1)

            let winning = results.first { $0.inserted }
            let winningClaim = try #require(winning)
            try await store.markRetrying(
                claimID: winningClaim.id,
                retryOwnerID: retryOwnerID,
                retryGeneration: winningClaim.retryGeneration,
                apnsErrorCode: APNsDeliveryFailureClassifier.transportErrorCode,
                on: app.db
            )

            let staleReclaim = try await store.reclaimRetrying(
                delivery,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                retryOwnerID: retryOwnerID,
                freshnessState: .fresh,
                on: app.db
            )
            #expect(staleReclaim.inserted == false)

            let staleTerminalized = try await store.completeRetryingFailure(
                delivery,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                retryOwnerID: retryOwnerID,
                apnsErrorCode: "StaleRetryWorker",
                on: app.db
            )
            #expect(staleTerminalized == false)

            let nextGeneration = try #require(
                try await store.loadRetryingDeliveries(
                    seriesID: seriesID,
                    revisionUrn: revisionUrn,
                    installationID: installationID,
                    retryOwnerID: retryOwnerID,
                    on: app.db
                ).first
            )
            #expect(nextGeneration.retryGeneration == delivery.retryGeneration + 1)
            let freshReclaim = try await store.reclaimRetrying(
                nextGeneration,
                seriesID: seriesID,
                revisionUrn: revisionUrn,
                retryOwnerID: retryOwnerID,
                freshnessState: .fresh,
                on: app.db
            )
            #expect(freshReclaim.inserted)
        }
    }

    @Test("retry exhaustion is scoped to the constrained installation")
    func retryExhaustionIsScoped() async throws {
        try await withIntegrationTestApplication(
            setup: .directPostgres,
            prepare: { app in try await bootstrapTables(on: app.db) }
        ) { app in
            let store = NotificationDeliveryStore()
            let seriesID = UUID()
            let revisionUrn = "urn:oid:retry-exhaustion"
            let firstInstallationID = UUID()
            let secondInstallationID = UUID()
            let payload = NotificationSendJobPayload(
                seriesId: seriesID,
                revisionUrn: revisionUrn,
                mode: .h3,
                reason: .new,
                installationId: firstInstallationID
            )
            let retryOwnerID = try #require(payload.deliveryAttemptId?.uuidString)
            try await seedSeries(id: seriesID, revisionUrn: revisionUrn, on: app.db)

            for installationID in [firstInstallationID, secondInstallationID] {
                try await seedInstallation(id: installationID, locationAuth: .always, on: app.db)
                let claim = try await store.claim(
                    installationID: installationID,
                    seriesID: seriesID,
                    revisionUrn: revisionUrn,
                    mode: .h3,
                    reason: .new,
                    freshnessState: .fresh,
                    retryOwnerID: retryOwnerID,
                    on: app.db
                )
                try await store.markRetrying(
                    claimID: claim.id,
                    retryOwnerID: retryOwnerID,
                    retryGeneration: claim.retryGeneration,
                    apnsErrorCode: APNsDeliveryFailureClassifier.transportErrorCode,
                    on: app.db
                )
            }

            try await NotificationSendJob(sender: RecordingNotificationSender()).error(
                makeQueueContext(app: app),
                NotificationDeliveryRetryableError.retryableFailures(1),
                payload
            )

            let rows = try await NotificationLedgerModel.query(on: app.db)
                .filter(\.$series.$id == seriesID)
                .filter(\.$revisionUrn == revisionUrn)
                .all()
            #expect(rows.first { $0.$deviceInstallation.id == firstInstallationID }?.status == "failed")
            #expect(rows.first { $0.$deviceInstallation.id == secondInstallationID }?.status == "retrying")
        }
    }

    @Test("notification retry policy is bounded and capped")
    func retryPolicyIsBounded() {
        let policy = NotificationSendRetryPolicy()
        let job = NotificationSendJob(sender: RecordingNotificationSender())

        #expect(policy.maximumRetryCount == 3)
        #expect((1...4).map(job.nextRetryIn(attempt:)) == [30, 120, 300, 300])
        #expect(NotificationSendJob.maximumRetryCount == policy.maximumRetryCount)
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

private enum ScriptedSenderOutcome: Sendable {
    case success
    case transportFailure
    case apns(status: Int, reason: String)
}

private actor ScriptedNotificationSender: NotificationSender {
    private var outcomesByToken: [String: [ScriptedSenderOutcome]]
    private(set) var sentTokens: [String] = []

    init(outcomesByToken: [String: [ScriptedSenderOutcome]]) {
        self.outcomesByToken = outcomesByToken
    }

    func sendNotification(
        app _: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to device: String,
        environment _: APNsEnvironment
    ) async throws {
        sentTokens.append(device)
        var outcomes = outcomesByToken[device] ?? []
        let outcome = outcomes.isEmpty ? .success : outcomes.removeFirst()
        outcomesByToken[device] = outcomes

        switch outcome {
        case .success:
            return
        case .transportFailure:
            throw ScriptedTransportFailure()
        case let .apns(status, reason):
            throw try makeTestAPNSError(status: status, reason: reason)
        }
    }
}

private struct RotatingTokenFailureSender: NotificationSender {
    let installationID: UUID
    let replacementToken: String

    func sendNotification(
        app: Application,
        with _: AlertDetails,
        hotAlertPayload _: HotAlertAPNsPayload,
        to _: String,
        environment _: APNsEnvironment
    ) async throws {
        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            UPDATE device_installations
            SET apns_device_token = \(bind: replacementToken),
                is_active = TRUE,
                updated_at = NOW()
            WHERE installation_id = \(bind: installationID)
            """).run()
        throw try makeTestAPNSError(status: 410, reason: "Unregistered")
    }
}

private struct ScriptedTransportFailure: Error {}

private func makeTestAPNSError(status: Int, reason: String) throws -> APNSError {
    let response = try JSONDecoder().decode(
        APNSErrorResponse.self,
        from: Data(#"{"reason":"\#(reason)"}"#.utf8)
    )
    return APNSError(responseStatus: status, apnsResponse: response)
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
