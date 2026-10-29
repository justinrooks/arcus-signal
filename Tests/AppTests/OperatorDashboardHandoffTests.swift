@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("Operator dashboard handoff evidence", .serialized, .sharedDatabase)
struct OperatorDashboardHandoffTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func classificationAndCompatibility() throws {
        for category in ["activeProcessing", "expiredLease", "failedHandoff", "inactive", "gated", "unclassified"] {
            let metric = StoredPipelineBacklogMetric(notificationHandoffs: [.init(category: category, count: 2, oldestAt: now)])
            let response = PipelineBacklogMetricResponse(refreshedAt: now, renderedAt: now, metric: metric)
            let expected: OperatorDashboardHealthState = ["expiredLease", "failedHandoff"].contains(category) ? .warning : category == "unclassified" ? .unknown : .healthy
            #expect(response.status == expected)
            #expect(PipelineBacklogMetricResponse(refreshedAt: now, renderedAt: now.addingTimeInterval(181), metric: metric).status == .unknown)
            #expect(PipelineBacklogMetricResponse(refreshedAt: now, renderedAt: now.addingTimeInterval(-1), metric: metric).status == .unknown)
            let html = OperatorDashboardPageRenderer.pipelineBacklogCard(response)
            #expect(html.contains(category))
            #expect(html.contains("never automatically reset dead intent"))
        }
        let legacy = try JSONDecoder().decode(StoredPipelineBacklogMetric.self, from: Data(#"{"pendingTargetDispatchCount":0,"pendingNotificationDispatchCount":0}"#.utf8))
        #expect(legacy.notificationHandoffs == nil)
        try verifyControlRoom(legacy)
        try verifyControlRoom(.init(notificationHandoffs: [.init(category: "failedHandoff", count: 1, oldestAt: now)]), renderedAt: now.addingTimeInterval(181))
        #expect(PipelineBacklogMetricResponse(refreshedAt: now, renderedAt: now, metric: legacy).status == .unknown)
        #expect(PipelineBacklogMetricResponse(refreshedAt: now, renderedAt: now, metric: .init(pendingNotificationDispatchCount: 1)).status == .unknown)
    }

    @Test func liveRenderingUsesTheSameEvidence() throws {
        let script = OperatorDashboardPageRenderer.liveUpdateScript(pollIntervalMilliseconds: 1000, initialGeneratedAtMilliseconds: 0, freshnessThresholdMilliseconds: 180000, initialSnapshotAgeMilliseconds: 0)
        let start = try #require(script.range(of: "function renderPipelineBacklogCard(metric)"))
        let end = try #require(script.range(of: "function renderStuckClaimedCard", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.lowerBound])
        #expect(function.contains(PipelineBacklogMetricResponse.handoffGuidance))
        #expect(script.contains("JSON.stringify(snapshot.redLights.pipelineBacklogAge)"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", """
            const formatDuration=String, formatDate=String;
            const renderCard=(title,primary,refreshed,lines,extra,status)=>JSON.stringify({lines,status});
            \(function)
            for (const category of ['activeProcessing','expiredLease','failedHandoff','inactive','gated','unclassified']) {
              const rendered=JSON.parse(renderPipelineBacklogCard({status:'warning',pendingTargetDispatchCount:0,pendingNotificationDispatchCount:0,handoffSummary:category,notificationHandoffs:[{category,count:2,oldestAt:'2026-10-29T00:00:00Z'}]}));
              if(!rendered.lines.some(l=>l.label===category+' · 2') || rendered.status!=='warning') process.exit(1);
            }
            """]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func collectorSeparatesLeaseFailureAndEligibility() async throws {
        guard let url = Environment.get("DATABASE_URL"),
              URL(string: url)?.lastPathComponent.hasPrefix("arcus_issue385_test_") == true else {
            throw Abort(.internalServerError, reason: "Requires an explicit arcus_issue385_test_ database")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.db.transaction { db in
                let sql = try #require(db as? any SQLDatabase)
                try await sql.raw("CREATE TEMP TABLE arcus_series (id UUID, current_revision_urn TEXT, state TEXT, ends TIMESTAMPTZ, expires TIMESTAMPTZ) ON COMMIT DROP").run()
                try await sql.raw("CREATE TEMP TABLE spc_mesos (product_key TEXT, valid_start TIMESTAMPTZ, valid_end TIMESTAMPTZ) ON COMMIT DROP").run()
                try await sql.raw("CREATE TEMP TABLE target_dispatch_outbox (id UUID, revision_urn TEXT, series_id UUID, payload JSONB, attempt_count INTEGER, last_error TEXT, dispatched TIMESTAMPTZ, created TIMESTAMPTZ, completed TIMESTAMPTZ, result TEXT) ON COMMIT DROP").run()
                try await sql.raw("""
                    CREATE TEMP TABLE notification_outbox (
                        id UUID, series_id UUID, revision_urn TEXT, mode TEXT, reason TEXT,
                        subject_kind TEXT, subject_id TEXT, subject_revision_id TEXT,
                        source_target_execution_id UUID, state TEXT, attempts INTEGER,
                        last_error TEXT, available_at TIMESTAMPTZ, created TIMESTAMPTZ, updated TIMESTAMPTZ
                    ) ON COMMIT DROP
                    """).run()
                let series = UUID()
                try await sql.raw("INSERT INTO arcus_series VALUES (\(bind: series), 'rev', 'active', NULL, \(bind: now.addingTimeInterval(600)))").run()
                try await sql.raw("INSERT INTO spc_mesos VALUES ('meso', \(bind: now.addingTimeInterval(-60)), \(bind: now.addingTimeInterval(600)))").run()
                for state in ["ready", "processing", "processing", "dead", "done"] {
                    // Two processing rows straddle the lease boundary, including equality.
                    let deadline = state == "processing" ? (try await sql.raw("SELECT COUNT(*) AS count FROM notification_outbox WHERE state = 'processing'").first(decoding: Count.self))?.count ?? 0 : 0
                    try await sql.raw("""
                        INSERT INTO notification_outbox (id, series_id, revision_urn, mode, reason, state, attempts, available_at, created, updated)
                        VALUES (\(bind: UUID()), \(bind: series), 'rev', 'ugc', 'new', \(bind: state), 0,
                                \(bind: now.addingTimeInterval(deadline == 0 ? 0 : 60)), \(bind: now), \(bind: now))
                        """).run()
                }
                try await sql.raw("""
                    INSERT INTO notification_outbox (id, series_id, revision_urn, state, available_at, updated)
                    VALUES (\(bind: UUID()), \(bind: series), 'old-rev', 'dead', \(bind: now), \(bind: now))
                    """).run()
                try await sql.raw("""
                    INSERT INTO notification_outbox (id, subject_kind, subject_id, state, available_at, updated)
                    VALUES (\(bind: UUID()), 'spc-meso', 'meso', 'dead', \(bind: now), \(bind: now)),
                           (\(bind: UUID()), 'future-kind', 'unknown', 'dead', \(bind: now), \(bind: now))
                    """).run()
                let collector = OperatorDashboardSnapshotRefresher()
                let metric = try await collector.loadPipelineBacklog(on: db, now: now, mesoEnabled: false)
                #expect(metric.pendingNotificationDispatchCount == 1)
                let groups = Dictionary(uniqueKeysWithValues: (metric.notificationHandoffs ?? []).map { ($0.category, $0.count) })
                #expect(groups == ["activeProcessing": 1, "expiredLease": 1, "failedHandoff": 1, "inactive": 1, "gated": 1, "unclassified": 1])
                #expect(metric.notificationHandoffs?.allSatisfy { $0.oldestAt != nil } == true)
                try verifyControlRoom(metric)
                // Distinct failure timestamps prove MIN selects the oldest observation.
                try await sql.raw("UPDATE notification_outbox SET updated = \(bind: now.addingTimeInterval(-120)) WHERE state = 'dead' AND revision_urn = 'rev'").run()
                let enabled = try await collector.loadPipelineBacklog(on: db, now: now, mesoEnabled: true)
                #expect(enabled.notificationHandoffs?.first { $0.category == "failedHandoff" }?.count == 2)
                #expect(enabled.notificationHandoffs?.first { $0.category == "failedHandoff" }?.oldestAt == now.addingTimeInterval(-120))
                #expect(enabled.notificationHandoffs?.first { $0.category == "expiredLease" }?.oldestAt == now)
                try verifyControlRoom(enabled)
                try await sql.raw("UPDATE arcus_series SET expires = \(bind: now)").run()
                try await sql.raw("UPDATE spc_mesos SET valid_end = \(bind: now)").run()
                let expired = try await collector.loadPipelineBacklog(on: db, now: now, mesoEnabled: true)
                #expect(expired.notificationHandoffs?.contains { $0.category == "failedHandoff" || $0.category == "expiredLease" } == false)
                #expect(expired.notificationHandoffs?.first { $0.category == "inactive" }?.count == 4)
                try await sql.raw("""
                    INSERT INTO notification_outbox (id, series_id, revision_urn, reason, state, available_at, updated)
                    VALUES (\(bind: UUID()), \(bind: series), 'rev', 'endedAllClear', 'dead', \(bind: now), \(bind: now))
                    """).run()
                try await sql.raw("INSERT INTO spc_mesos VALUES ('future', \(bind: now.addingTimeInterval(60)), \(bind: now.addingTimeInterval(600)))").run()
                try await sql.raw("""
                    INSERT INTO notification_outbox (id, subject_kind, subject_id, state, available_at, updated)
                    VALUES (\(bind: UUID()), 'spc-meso', 'future', 'dead', \(bind: now), \(bind: now))
                    """).run()
                let uncertain = try await collector.loadPipelineBacklog(on: db, now: now, mesoEnabled: true)
                #expect(uncertain.notificationHandoffs?.first { $0.category == "unclassified" }?.count == 2)
                #expect(uncertain.notificationHandoffs?.first { $0.category == "inactive" }?.count == 5)
            }
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func verifyControlRoom(_ metric: StoredPipelineBacklogMetric, renderedAt: Date? = nil) throws {
        var snapshot = OperatorDashboardStoredSnapshot.empty(now: now)
        snapshot.fastRefreshedAt = now
        snapshot.pipelineBacklog = metric
        let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: renderedAt ?? now)
        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(OperatorDashboardSnapshotResponse.self, from: encoded)
        #expect(decoded.redLights.pipelineBacklogAge.notificationHandoffs?.count == metric.notificationHandoffs?.count)
        let ssr = OperatorDashboardPageRenderer.healthOverview(decoded.redLights)
        let summary = decoded.redLights.pipelineBacklogAge.handoffSummary
        #expect(ssr.contains(summary))
        #expect(ssr.contains("Notification handoffs need inspection") == (decoded.redLights.pipelineBacklogAge.status == .warning))
        #expect(ssr.contains(PipelineBacklogMetricResponse.handoffGuidance))
        let script = OperatorDashboardPageRenderer.liveUpdateScript(pollIntervalMilliseconds: 1000, initialGeneratedAtMilliseconds: 0, freshnessThresholdMilliseconds: 180000, initialSnapshotAgeMilliseconds: 0)
        let start = try #require(script.range(of: "function renderHealthOverview(r, anvil)"))
        let end = try #require(script.range(of: "function renderModelOverview", range: start.upperBound..<script.endIndex))
        let function = String(script[start.lowerBound..<end.lowerBound])
        let json = try #require(String(data: encoded, encoding: .utf8))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "-e", """
            const formatDuration=String,controlTime=String,escapeHtml=String;
            const anvilFindingSummary=()=>null,controlHealthItem=(...args)=>args.join(' ');
            \(function)
            const snapshot=\(json);
            const html=renderHealthOverview(snapshot.redLights);
            if(!html.includes(snapshot.redLights.pipelineBacklogAge.handoffSummary) || html.includes('Notification handoffs need inspection') !== (snapshot.redLights.pipelineBacklogAge.status==='warning')) process.exit(1);
            """]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private struct Count: Decodable { let count: Int }
}
