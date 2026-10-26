import Foundation
import Vapor

/// A /version observation establishes reachability and import readiness only, never analysis success.
/// The standard worker refresh probes every 60 seconds with one 3-second request (no retries).
/// Three consecutive transport failures are critical; the first two are unknown. Success clears failures.
/// Reachable HTTP/contract failures stay unknown and break a transport-failure streak.
/// Observations older than 180 seconds or future-dated render unknown, independently of snapshot age.
/// A gap beyond 180 seconds restarts failure accumulation. Last successful identity/readiness remain
/// dated diagnostic context during failures or missing configuration. No expected release is inferred.
/// Only bounded identity tokens and fixed failure categories are exposed, never raw errors or bodies.
public struct AnvilServiceObservation: Codable, Sendable {
    static let freshnessSeconds: TimeInterval = 180
    static let criticalFailureCount = 3

    public var status: OperatorDashboardHealthState = .unknown
    public var checkedAt: Date?
    public var lastSuccessfulAt: Date?
    public var sharppyAvailable: Bool?
    public var version: String?
    public var revision: String?
    /// Consecutive failures of the same category, bounded at the critical threshold.
    public var consecutiveFailures: Int = 0
    public var recentFailure: Failure?

    public enum Failure: String, Codable, Sendable {
        case transport, httpStatus, invalidPayload
    }

    func rendered(at now: Date) -> Self {
        var result = self
        guard let checkedAt, (0...Self.freshnessSeconds).contains(now.timeIntervalSince(checkedAt)) else {
            result.status = .unknown
            return result
        }
        return result
    }

    func failed(_ failure: Failure, at now: Date) -> Self {
        var result = self
        // A gap or a different failure category cannot establish a continuous transport outage.
        let previousCount = checkedAt.flatMap { date in
            recentFailure == failure && (0...Self.freshnessSeconds).contains(now.timeIntervalSince(date)) ? consecutiveFailures : nil
        } ?? 0
        result.consecutiveFailures = min(previousCount + 1, Self.criticalFailureCount)
        result.checkedAt = now
        result.recentFailure = failure
        result.status = failure == .transport && result.consecutiveFailures >= Self.criticalFailureCount ? .critical : .unknown
        return result
    }
}

struct AnvilServiceObserver: Sendable {
    let httpClient: any HTTPClient
    let baseURL: URL?

    func observe(previous: AnvilServiceObservation?, now: Date) async throws -> AnvilServiceObservation {
        guard let baseURL, ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil else {
            var result = previous ?? .init()
            result.status = .unknown
            result.consecutiveFailures = 0
            result.recentFailure = nil
            return result
        }
        let previous = previous ?? .init()
        let response: HTTPResponse
        do {
            response = try await httpClient.get(
                Self.versionEndpoint(from: baseURL),
                headers: ["Accept": "application/json"],
                timeoutSeconds: 3
            )
            try Task.checkCancellation()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return previous.failed(.transport, at: now)
        }
        guard response.status == 200 else { return previous.failed(.httpStatus, at: now) }
        guard let data = response.data, data.count <= 16_384,
              let payload = try? JSONDecoder().decode(VersionPayload.self, from: data),
              payload.service == "arcus-anvil", payload.analysisEngine.name == "sharppy",
              Self.safeIdentity(payload.version),
              payload.revision.map(Self.safeIdentity) ?? true else {
            return previous.failed(.invalidPayload, at: now)
        }
        var result = AnvilServiceObservation()
        result.status = payload.analysisEngine.available ? .healthy : .warning
        result.checkedAt = now
        result.lastSuccessfulAt = now
        result.sharppyAvailable = payload.analysisEngine.available
        result.version = payload.version
        result.revision = payload.revision
        return result
    }

    static func versionEndpoint(from baseURL: URL) -> URL {
        // Profile analysis uses /api/v1/analyze-profile; identity is outside /api.
        let serviceURL = baseURL.lastPathComponent == "api" ? baseURL.deletingLastPathComponent() : baseURL
        return serviceURL.appendingPathComponent("version")
    }

    // Identity is diagnostic text, never an arbitrary upstream error/body/endpoint.
    private static func safeIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95, 43].contains($0)
        }
    }

    private struct VersionPayload: Decodable {
        let service: String
        let version: String
        let revision: String?
        let analysisEngine: Engine
        struct Engine: Decodable {
            let name: String
            let available: Bool
        }
    }
}
