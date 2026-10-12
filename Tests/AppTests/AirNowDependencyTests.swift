@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor

@Suite("AirNow dependency evidence", .serialized)
struct AirNowDependencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Real HTTP outcomes remain distinct and cache hits are not attempts")
    func outcomes() async throws {
        let cases: [(Int, Data?, AirNowDependencyOutcome)] = [
            (200, Data("[{\"dateObserved\":\"2026-07-12\",\"hourObserved\":\"14:00\",\"nowcastAQI\":20}]".utf8), .usableAQI),
            (200, Data("[]".utf8), .noUsableObservation),
            (503, nil, .httpFailure), (429, nil, .httpFailure),
            (200, Data("invalid".utf8), .decodeFailure), (200, nil, .missingData),
            (204, nil, .missingData)
        ]
        for (code, data, expected) in cases {
            let recorder = RecordingStub()
            let http = HTTPStub(response: .init(status: code, headers: [:], data: data))
            let provider = DefaultAirQualityProvider(
                configuration: .init(airNowAPIKey: "secret-test-key", cacheLifetime: 2700),
                client: DefaultAirNowClient(apiKey: "secret-test-key", http: http),
                h3Resolver: H3Stub(), recorder: recorder, now: { now }
            )
            let response = try await provider.currentResponse(for: 1)
            #expect((response != nil) == (expected == .usableAQI))
            let events = await recorder.events
            #expect(events.count == 1)
            #expect(events.first?.outcome == expected)
            #expect(events.first?.httpStatus == code)
            #expect(events.first?.attemptedAt == now)
            #expect(events.first?.durationMilliseconds != nil)
            if code == 200 && (expected == .usableAQI || expected == .noUsableObservation) {
                _ = try await provider.currentResponse(for: 1)
                #expect(await recorder.events.count == 1)
            }
        }
    }

    @Test("Transport, cancellation and disabled configuration preserve endpoint behavior")
    func unavailable() async throws {
        let recorder = RecordingStub()
        let provider = DefaultAirQualityProvider(
            configuration: .init(airNowAPIKey: "test", cacheLifetime: 2700),
            client: DefaultAirNowClient(apiKey: "test", http: HTTPStub(response: nil)),
            h3Resolver: H3Stub(), recorder: recorder, now: { now }
        )
        #expect(try await provider.currentResponse(for: 1) == nil)
        #expect(await recorder.events.first?.outcome == .transportFailure)
        #expect(await recorder.events.first?.httpStatus == nil)
        let cancellationRecorder = RecordingStub()
        let cancelled = DefaultAirQualityProvider(
            configuration: .init(airNowAPIKey: "test", cacheLifetime: 2700),
            client: CancelledClient(), h3Resolver: H3Stub(), recorder: cancellationRecorder
        )
        await #expect(throws: CancellationError.self) { try await cancelled.currentResponse(for: 1) }
        #expect(await cancellationRecorder.events.isEmpty)
        let disabled = UnavailableAirQualityProvider(recorder: recorder)
        #expect(try await disabled.currentResponse(for: 1) == nil)
        #expect(await recorder.events.last?.outcome == .disabled)
        #expect(await recorder.events.last?.attemptedAt == nil)
        #expect(AirQualityConfiguration.resolved(from: [:]).airNowAPIKey == nil)
    }

    @Test("Critical requires sustained failures and recovery clears the streak")
    func classification() {
        var metric = AirNowDependencyStatus()
        #expect(metric.health(at: now) == .unknown)
        metric.apply(.init(attemptedAt: now, completedAt: now, outcome: .usableAQI, httpStatus: 200))
        #expect(metric.health(at: now) == .healthy)
        #expect(metric.lastAttemptAt == now)
        #expect(metric.lastUpstreamSuccessAt == now)
        #expect(metric.lastUsableAQIAt == now)
        metric.apply(.init(attemptedAt: now.addingTimeInterval(1), completedAt: now.addingTimeInterval(1), outcome: .httpFailure, httpStatus: 503))
        #expect(metric.health(at: now.addingTimeInterval(10000)) == .warning)
        metric.apply(.init(attemptedAt: now.addingTimeInterval(5400), completedAt: now.addingTimeInterval(5400), outcome: .noUsableObservation, httpStatus: 200))
        #expect(metric.health(at: now.addingTimeInterval(5400)) == .warning)
        #expect(metric.health(at: now.addingTimeInterval(10000)) == .warning)
        metric.apply(.init(attemptedAt: now.addingTimeInterval(5401), completedAt: now.addingTimeInterval(5401), outcome: .transportFailure))
        #expect(metric.health(at: now.addingTimeInterval(5401)) == .critical)
        #expect(metric.lastUpstreamSuccessAt == now.addingTimeInterval(5400))
        #expect(metric.lastUsableAQIAt == now)
        metric.apply(.init(attemptedAt: now.addingTimeInterval(5402), completedAt: now.addingTimeInterval(5402), outcome: .usableAQI, httpStatus: 200))
        #expect(metric.health(at: now.addingTimeInterval(5402)) == .healthy)
        #expect(metric.consecutiveFailures == 0)
        #expect(metric.failureStartedAt == nil)
        #expect(metric.httpStatus == 200)
        // A late failure cannot regress recovery.
        metric.apply(.init(attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 429))
        #expect(metric.health(at: now.addingTimeInterval(5402)) == .healthy)
        metric.apply(.init(attemptedAt: nil, completedAt: now.addingTimeInterval(5403), outcome: .disabled))
        #expect(metric.health(at: now.addingTimeInterval(20000)) == .warning)
        #expect(metric.httpStatus == nil)
    }

    @Test("Delayed successes retain watermarks without fabricating a sustained streak")
    func delayedSuccess() {
        var metric = AirNowDependencyStatus()
        metric.apply(.init(attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 503))
        let latest = now.addingTimeInterval(6000)
        metric.apply(.init(attemptedAt: latest, completedAt: latest, outcome: .transportFailure))
        #expect(metric.health(at: latest) == .critical)
        let recovery = now.addingTimeInterval(3000)
        metric.apply(.init(attemptedAt: recovery, completedAt: recovery, outcome: .usableAQI, httpStatus: 200))
        #expect(metric.outcome == .transportFailure)
        #expect(metric.lastUsableAQIAt == recovery)
        #expect(metric.lastUpstreamSuccessAt == recovery)
        #expect(metric.lastAttemptAt == latest)
        #expect(metric.consecutiveFailures == 1)
        #expect(metric.health(at: latest.addingTimeInterval(10000)) == .warning)
    }

    @Test("Distinct tied outcomes are stable in either order; idle failures cannot become critical")
    func tiedOutcomes() {
        let low = AirNowDependencyEvent(id: "a", attemptedAt: now, completedAt: now, outcome: .usableAQI, httpStatus: 200)
        let high = AirNowDependencyEvent(id: "b", attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 503)
        for events in [[low, high], [high, low]] {
            var metric = AirNowDependencyStatus()
            for event in events { metric.apply(event) }
            #expect(metric.outcome == .httpFailure)
            #expect(metric.httpStatus == 503)
            #expect(metric.consecutiveFailures == 1)
            #expect(metric.lastUsableAQIAt == now)
            #expect(metric.health(at: now.addingTimeInterval(10000)) == .warning)
        }
        let failedLow = AirNowDependencyEvent(id: "a", attemptedAt: now, completedAt: now, outcome: .transportFailure)
        for events in [[failedLow, high], [high, failedLow]] {
            var metric = AirNowDependencyStatus()
            for event in events { metric.apply(event) }
            #expect(metric.consecutiveFailures == 1)
            #expect(metric.outcome == .httpFailure)
            metric.apply(.init(attemptedAt: now.addingTimeInterval(1), completedAt: now.addingTimeInterval(1), outcome: .transportFailure))
            #expect(metric.health(at: now.addingTimeInterval(10000)) == .warning)
        }
        var overlapping = AirNowDependencyStatus()
        overlapping.apply(.init(attemptedAt: now.addingTimeInterval(1), completedAt: now.addingTimeInterval(2), outcome: .httpFailure, httpStatus: 503))
        overlapping.apply(.init(attemptedAt: now, completedAt: now.addingTimeInterval(3), outcome: .usableAQI, httpStatus: 200))
        #expect(overlapping.health(at: now.addingTimeInterval(3)) == .healthy)
        #expect(overlapping.lastAttemptAt == now.addingTimeInterval(1))
    }

    @Test("Old snapshots decode and Red Lights exposes AirNow in SSR and live rendering")
    func compatibilityAndRendering() throws {
        var snapshot = OperatorDashboardStoredSnapshot.empty(now: now)
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        json.removeValue(forKey: "airNow")
        json["schemaVersion"] = 10
        let legacy = try JSONDecoder().decode(OperatorDashboardStoredSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(legacy.airNow.health(at: now) == .unknown)
        snapshot.airNow.apply(.init(attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 503))
        let red = OperatorDashboardRedLightsSectionResponse(snapshot: snapshot, renderedAt: now)
        #expect(red.airQuality.status == .warning)
        let html = OperatorDashboardPageRenderer.healthOverview(red)
        #expect(html.contains("Air Quality / AirNow"))
        #expect(html.contains("AirNow HTTP 503"))
        #expect(!html.contains("Inspect NWS Activity"))
        #expect(html.contains("Last real attempt:"))
        #expect(html.contains("Last usable AQI:"))
        let encoded = String(decoding: try encoder.encode(red.airQuality), as: UTF8.self)
        #expect(encoded.contains("httpFailure"))
        #expect(!encoded.contains("h3"))
        let live = OperatorDashboardPageRenderer.liveUpdateScript(
            pollIntervalMilliseconds: 1000, initialGeneratedAtMilliseconds: 0,
            freshnessThresholdMilliseconds: 10000, initialSnapshotAgeMilliseconds: 0
        )
        #expect(live.contains("controlHealthItem('Air Quality / AirNow'"))
        #expect(live.contains("Last HTTP success:"))
        #expect(live.contains("Last usable AQI:"))
    }
}

private actor RecordingStub: AirNowDependencyRecording {
    var events: [AirNowDependencyEvent] = []
    func record(_ event: AirNowDependencyEvent) { events.append(event) }
}

private struct H3Stub: StormSetupH3Resolving {
    func resolve(h3Cell: Int64) throws -> StormSetupResolvedH3Cell {
        .init(h3Cell: h3Cell, centroid: .init(latitude: 39, longitude: -104))
    }
}

private struct HTTPStub: App.HTTPClient {
    let response: HTTPResponse?
    func get(_ url: URL, headers: [String: String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        guard let response else { throw URLError(.cannotConnectToHost) }
        return response
    }
    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { try await get(url, headers: headers, timeoutSeconds: nil) }
    func post(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { try await get(url, headers: headers, timeoutSeconds: nil) }
    func postWithoutRetry(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { try await get(url, headers: headers, timeoutSeconds: nil) }
    func clearCache() {}
}

private struct CancelledClient: AirNowClient {
    func fetchCurrentObservations(latitude: Double, longitude: Double) async throws -> AirNowObservationsResponse { throw CancellationError() }
}

@Suite("AirNow cross-process persistence", .serialized)
struct AirNowDependencyPersistenceTests {
    @Test("API evidence survives separate application reads and fast snapshot refresh")
    func persistenceAndSnapshot() async throws {
        let api = try await Application.make(.testing)
        let dashboard = try await Application.make(.testing)
        do {
            try await configure(api, mode: .api)
            try await api.autoMigrate()
            try await configure(dashboard, mode: .worker)
            let sql = try #require(api.db as? any SQLDatabase)
            try await sql.raw("DELETE FROM airnow_dependency_status").run()
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            try await AirNowConfigurationLifecycle(configured: false).didBootAsync(api)
            #expect(try await AirNowDependencyStore.load(on: dashboard.db).outcome == .disabled)
            #expect(try await AirNowDependencyStore.load(on: dashboard.db).lastAttemptAt == nil)
            try await AirNowConfigurationLifecycle(configured: true).didBootAsync(api)
            #expect(try await AirNowDependencyStore.load(on: dashboard.db).outcome == .unknown)
            try await sql.raw("DELETE FROM airnow_dependency_status").run()
            try await AirNowDependencyStore.record(.init(attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 503), on: api.db)
            var baseline = OperatorDashboardStoredSnapshot.empty(now: now)
            baseline.standardRefreshedAt = now
            baseline.slowRefreshedAt = now
            try await dashboard.operatorDashboardSnapshotStore.save(baseline, on: dashboard.db)
            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: dashboard, now: now)
            let snapshot = try #require(try await dashboard.operatorDashboardSnapshotStore.load(on: dashboard.db))
            #expect(snapshot.airNow.httpStatus == 503)
            #expect(snapshot.airNow.outcome == .httpFailure)
            #expect(snapshot.fastRefreshedAt == now)
            #expect(snapshot.standardRefreshedAt == now)
            // Concurrent duplicate recordings are idempotent; a late failure
            // cannot replace the newer usable outcome.
            let recovery = AirNowDependencyEvent(attemptedAt: now.addingTimeInterval(1), completedAt: now.addingTimeInterval(1), outcome: .usableAQI, httpStatus: 200)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask { try await AirNowDependencyStore.record(recovery, on: api.db) }
                }
                try await group.waitForAll()
            }
            try await AirNowDependencyStore.record(.init(attemptedAt: now, completedAt: now, outcome: .transportFailure), on: api.db)
            let recovered = try await AirNowDependencyStore.load(on: dashboard.db)
            #expect(recovered.health(at: now) == .healthy)
            #expect(recovered.lastUsableAQIAt == recovery.completedAt)
            #expect(recovered.consecutiveFailures == 0)
            for reverse in [false, true] {
                try await sql.raw("DELETE FROM airnow_dependency_status").run()
                let tiedSuccess = AirNowDependencyEvent(id: "a", attemptedAt: now, completedAt: now, outcome: .usableAQI, httpStatus: 200)
                let tiedFailure = AirNowDependencyEvent(id: "b", attemptedAt: now, completedAt: now, outcome: .httpFailure, httpStatus: 503)
                let events = reverse ? [tiedFailure, tiedSuccess] : [tiedSuccess, tiedFailure]
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for event in events {
                        group.addTask { try await AirNowDependencyStore.record(event, on: api.db) }
                    }
                    try await group.waitForAll()
                }
                let tied = try await AirNowDependencyStore.load(on: dashboard.db)
                #expect(tied.outcome == .httpFailure)
                #expect(tied.httpStatus == 503)
                #expect(tied.consecutiveFailures == 1)
                #expect(tied.lastUsableAQIAt == now)
            }
            // Unavailable telemetry storage never turns an AQI result into an error.
            try await CreateAirNowDependencyStatus().revert(on: api.db)
            let provider = DefaultAirQualityProvider(
                configuration: .init(airNowAPIKey: "test", cacheLifetime: 2700),
                client: DefaultAirNowClient(apiKey: "test", http: HTTPStub(response: .init(
                    status: 200, headers: [:],
                    data: Data("[{\"dateObserved\":\"2026-07-12\",\"hourObserved\":\"14:00\",\"nowcastAQI\":20}]".utf8)
                ))), h3Resolver: H3Stub(),
                recorder: DatabaseAirNowDependencyRecorder(database: api.db, logger: api.logger)
            )
            #expect(try await provider.currentResponse(for: 1)?.aqi == 20)
            try await CreateAirNowDependencyStatus().prepare(on: api.db)
            #expect(try await AirNowDependencyStore.load(on: dashboard.db).outcome == .unknown)
        } catch {
            try? await api.asyncShutdown()
            try? await dashboard.asyncShutdown()
            throw error
        }
        try await api.asyncShutdown()
        try await dashboard.asyncShutdown()
    }
}
