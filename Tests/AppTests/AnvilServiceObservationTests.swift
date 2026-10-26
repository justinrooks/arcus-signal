@testable import App
import Foundation
import Fluent
import ArcusCore
import Testing
import Vapor
import VaporTesting

@Suite("Anvil service observation", .serialized, .sharedDatabase)
struct AnvilServiceObservationTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let baseURL = URL(string: "https://anvil.example/service/api")!

    private func client(available: Bool = true) -> ObservationHTTPClient {
        .init(body: """
        {"service":"arcus-anvil","version":"v1.2.3","revision":"abc123","analysisEngine":{"name":"sharppy","available":\(available)}}
        """)
    }

    @Test(arguments: [true, false])
    func readiness(available: Bool) async throws {
        let http = client(available: available)
        let result = try await AnvilServiceObserver(httpClient: http, baseURL: baseURL).observe(previous: nil, now: now)
        #expect(result.status == (available ? .healthy : .warning))
        #expect(result.checkedAt == now && result.lastSuccessfulAt == now)
        #expect(result.version == "v1.2.3" && result.revision == "abc123")
        #expect(result.sharppyAvailable == available)
        #expect(await http.calls == 1)
    }

    @Test
    func endpointsAndNullableRevision() async throws {
        for path in ["", "/", "/api", "/api/"] {
            let base = try #require(URL(string: "https://anvil.example" + path))
            #expect(AnvilServiceObserver.versionEndpoint(from: base).absoluteString == "https://anvil.example/version")
        }
        let http = ObservationHTTPClient(body: #"{"service":"arcus-anvil","version":"development","revision":null,"analysisEngine":{"name":"sharppy","available":true}}"#)
        let observation = try await AnvilServiceObserver(httpClient: http, baseURL: baseURL).observe(previous: nil, now: now)
        #expect(observation.status == .healthy && observation.revision == nil)
        let unconfigured = try await AnvilServiceObserver(httpClient: http, baseURL: nil).observe(previous: observation, now: now.addingTimeInterval(60))
        #expect(unconfigured.status == .unknown && unconfigured.lastSuccessfulAt == now)
        #expect(unconfigured.version == "development")
    }

    @Test
    func analysisEndpointRemainsUnderAPI() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "AnvilAnalyzeProfileRequest", withExtension: "json", subdirectory: "Fixtures"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let request = try decoder.decode(AnvilAnalyzeProfileRequest.self, from: Data(contentsOf: fixture))
        let http = client()
        let analysis = DefaultAnvilProfileClient(baseURL: try #require(URL(string: "https://anvil.example/api")), timeoutSeconds: 10, httpClient: http)
        await #expect(throws: CancellationError.self) { try await analysis.analyzeProfile(request) }
        #expect(await http.calls == 1)
    }

    @Test
    func outageRecoveryAndFreshness() async throws {
        let observer = AnvilServiceObserver(httpClient: client(), baseURL: baseURL)
        let healthy = try await observer.observe(previous: nil, now: now)
        var result = healthy
        for count in 1...3 {
            result = result.failed(.transport, at: now.addingTimeInterval(Double(count * 60)))
            #expect(result.status == (count == 3 ? .critical : .unknown))
            #expect(result.consecutiveFailures == count)
            #expect(result.lastSuccessfulAt == now && result.version == healthy.version)
        }
        #expect(result.rendered(at: now.addingTimeInterval(361)).status == .unknown)
        #expect(result.failed(.transport, at: now.addingTimeInterval(361)).consecutiveFailures == 1)
        #expect(healthy.rendered(at: now.addingTimeInterval(180)).status == .healthy)
        #expect(healthy.rendered(at: now.addingTimeInterval(181)).status == .unknown)
        #expect(healthy.rendered(at: now.addingTimeInterval(-1)).status == .unknown)
        let recovered = try await observer.observe(previous: result, now: now.addingTimeInterval(240))
        #expect(recovered.status == .healthy && recovered.consecutiveFailures == 0)
        #expect(recovered.recentFailure == nil && recovered.lastSuccessfulAt == now.addingTimeInterval(240))
    }

    @Test(arguments: ["", "{}", "null", "{broken", "{\"service\":\"other\"}",
        #"{"service":"other","version":"v1.2.3","analysisEngine":{"name":"sharppy","available":true}}"#,
        #"{"service":"arcus-anvil","version":"v1.2.3","analysisEngine":{"name":"other","available":true}}"#,
        "{\"service\":\"arcus-anvil\",\"version\":\"https://secret\",\"analysisEngine\":{\"name\":\"sharppy\",\"available\":true}}"])
    func malformed(body: String) async throws {
        let result = try await AnvilServiceObserver(httpClient: ObservationHTTPClient(body: body), baseURL: baseURL)
            .observe(previous: nil, now: now)
        #expect(result.status == .unknown && result.recentFailure == .invalidPayload)
        #expect(result.version == nil && result.lastSuccessfulAt == nil)
    }

    @Test(arguments: [401, 404, 503, 200])
    func repeatedReachableFailuresRemainUnknown(status: Int) async throws {
        let healthy = try await AnvilServiceObserver(httpClient: client(), baseURL: baseURL).observe(previous: nil, now: now)
        let observer = AnvilServiceObserver(
            httpClient: ObservationHTTPClient(body: #"{"service":"arcus-anvil","version":"v1.2.3","analysisEngine":{"name":"unsupported","available":true}}"#, status: status),
            baseURL: baseURL
        )
        var result = healthy
        for count in 1...4 {
            let checkedAt = now.addingTimeInterval(Double(count * 60))
            result = try await observer.observe(previous: result, now: checkedAt)
            #expect(result.status == .unknown)
            #expect(result.recentFailure == (status == 200 ? .invalidPayload : .httpStatus))
            #expect(result.consecutiveFailures == min(count, AnvilServiceObservation.criticalFailureCount))
            #expect(result.checkedAt == checkedAt && result.lastSuccessfulAt == now)
            #expect(result.version == healthy.version && result.revision == healthy.revision)
        }
    }

    @Test(arguments: [AnvilServiceObservation.Failure.httpStatus, .invalidPayload])
    func reachableFailureBreaksTransportOutageStreak(failure: AnvilServiceObservation.Failure) {
        var result = AnvilServiceObservation()
        for (index, category) in [AnvilServiceObservation.Failure.transport, .transport, failure, .transport, .transport, .transport].enumerated() {
            result = result.failed(category, at: now.addingTimeInterval(Double(index * 60)))
            #expect(result.status == (index == 5 ? .critical : .unknown))
            if index == 3 { #expect(result.consecutiveFailures == 1) }
        }
    }

    @Test
    func unconfiguredAndFailures() async throws {
        let http = client()
        let result = try await AnvilServiceObserver(httpClient: http, baseURL: nil).observe(previous: nil, now: now)
        #expect(result.status == .unknown && result.checkedAt == nil)
        #expect(await http.calls == 0)
        for transport in [false, true] {
            let http = ObservationHTTPClient(body: "private upstream body", status: 503, transportFailure: transport)
            let failed = try await AnvilServiceObserver(httpClient: http, baseURL: baseURL).observe(previous: nil, now: now)
            #expect(failed.recentFailure == (transport ? .transport : .httpStatus))
            #expect(failed.status == .unknown)
            #expect(await http.calls == 1)
            #expect(!String(decoding: try JSONEncoder().encode(failed), as: UTF8.self).contains("private"))
        }
    }

    @Test
    func cancellationIsNotAnOutage() async throws {
        let observer = AnvilServiceObserver(
            httpClient: ObservationHTTPClient(body: "", cancelled: true), baseURL: baseURL
        )
        await #expect(throws: CancellationError.self) {
            try await observer.observe(previous: nil, now: now)
        }
    }

    @Test
    func backwardDecodeAndIndependentFreshness() async throws {
        var snapshot = OperatorDashboardStoredSnapshot(schemaVersion: 11, generatedAt: now)
        let oldData = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(OperatorDashboardStoredSnapshot.self, from: oldData).anvil == nil)
        snapshot.anvil = try await AnvilServiceObserver(httpClient: client(), baseURL: baseURL).observe(previous: nil, now: now)
        snapshot.generatedAt = now.addingTimeInterval(181)
        let decoded = try JSONDecoder().decode(OperatorDashboardStoredSnapshot.self, from: JSONEncoder().encode(snapshot))
        let response = OperatorDashboardSnapshotResponse(snapshot: decoded, renderedAt: snapshot.generatedAt)
        #expect(response.anvil?.status == .unknown)
        #expect(response.anvil?.lastSuccessfulAt == now)
    }

    @Test
    func workerPersistenceFailureAndMetrics() async throws {
        let rawURL = Environment.get("DATABASE_URL")
        let name = rawURL.flatMap(URL.init(string:))?.lastPathComponent ?? Environment.get("DATABASE_NAME") ?? ""
        guard name.range(of: #"^arcus_issue[0-9]+_(test|validation)(_|$)"#, options: .regularExpression) != nil else {
            throw Abort(.badRequest, reason: "An issue-scoped database is required")
        }
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            app.stormSetupConfiguration = .resolved(from: ["ANVIL_PROFILE_ANALYSIS_BASE_URL": baseURL.absoluteString])
            let http = client()
            let refresher = OperatorDashboardSnapshotRefresher(anvilHTTPClient: http)
            try await refresher.refreshIfDue(on: app, forceAll: true, now: now)
            let saved = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            #expect(saved.anvil?.status == .healthy)
            // Fast-only refresh must not poll Anvil or rejuvenate its observation.
            try await refresher.refreshIfDue(on: app, now: now.addingTimeInterval(30))
            #expect(await http.calls == 1)
            let failing = OperatorDashboardSnapshotRefresher(anvilHTTPClient: ObservationHTTPClient(body: "", transportFailure: true))
            for count in 1...3 {
                try await failing.refreshIfDue(on: app, now: now.addingTimeInterval(Double(count * 60)))
            }
            let failed = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            #expect(failed.anvil?.status == .critical)
            #expect(failed.fastRefreshedAt == now.addingTimeInterval(180))
            #expect(failed.anvil?.lastSuccessfulAt == now)
            // Exercise the existing metrics controller projection with actual persisted JSON.
            try await app.testing().test(.GET, "/v1/metrics", afterResponse: { response async throws in
                #expect(response.status == .ok)
                let metrics = try response.content.decode(OperatorDashboardSnapshotResponse.self)
                #expect(metrics.anvil?.status == failed.anvil?.rendered(at: metrics.renderedAt).status)
                #expect(metrics.anvil?.version == "v1.2.3")
            })
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}

private actor ObservationHTTPClient: App.HTTPClient {
    let body: String
    let status: Int
    let transportFailure: Bool
    let cancelled: Bool
    var calls = 0
    init(body: String, status: Int = 200, transportFailure: Bool = false, cancelled: Bool = false) {
        self.body = body
        self.status = status
        self.transportFailure = transportFailure
        self.cancelled = cancelled
    }
    func get(_ url: URL, headers: [String: String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        #expect(url.absoluteString == "https://anvil.example/service/version")
        #expect(headers["Accept"] == "application/json" && timeoutSeconds == 3)
        calls += 1
        if cancelled { throw CancellationError() }
        if transportFailure { throw URLError(.timedOut) }
        return .init(status: status, headers: [:], data: Data(body.utf8))
    }
    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { fatalError("Unexpected HEAD") }
    func post(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { fatalError("Unexpected POST") }
    func postWithoutRetry(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        #expect(url.absoluteString == "https://anvil.example/api/v1/analyze-profile")
        calls += 1
        throw CancellationError()
    }
    nonisolated func clearCache() {}
}
