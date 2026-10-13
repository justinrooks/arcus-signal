import Fluent
import FluentSQL
import Foundation
import Vapor

public enum AirNowDependencyOutcome: String, Codable, Sendable {
    case usableAQI, noUsableObservation, httpFailure, transportFailure
    case decodeFailure, missingData, invalidRequest, disabled, unknown

    var summary: String {
        switch self {
        case .usableAQI: "Usable AQI received"
        case .noUsableObservation: "No usable AQI observation"
        case .httpFailure: "Upstream HTTP failure"
        case .transportFailure: "Transport failure"
        case .decodeFailure: "Decode/contract failure"
        case .missingData: "Missing response data"
        case .invalidRequest: "Invalid upstream request"
        case .disabled: "Disabled / API key not configured"
        case .unknown: "Awaiting upstream evidence"
        }
    }
}

/// A singleton operational record. No request, location, device, or AQI data.
public struct AirNowDependencyStatus: Codable, Sendable {
    public var outcome: AirNowDependencyOutcome = .unknown
    public var lastAttemptAt: Date?
    public var lastUpstreamSuccessAt: Date?
    public var lastUsableAQIAt: Date?
    public var httpStatus: Int?
    public var durationMilliseconds: Int?
    public var consecutiveFailures: Int = 0
    public var failureStartedAt: Date?
    public var updatedAt: Date?
    var updateID: String = ""

    public init() {}

    mutating func apply(_ event: AirNowDependencyEvent) {
        // Success/attempt watermarks survive delayed writes independently of
        // the latest outcome. Failure context counts accepted completion-order
        // updates, conservatively excluding late failures and duplicate writes.
        if let attemptedAt = event.attemptedAt {
            lastAttemptAt = max(lastAttemptAt ?? attemptedAt, attemptedAt)
        }
        if let status = event.httpStatus, (200...299).contains(status) {
            lastUpstreamSuccessAt = max(lastUpstreamSuccessAt ?? event.completedAt, event.completedAt)
        }
        if event.outcome == .usableAQI {
            lastUsableAQIAt = max(lastUsableAQIAt ?? event.completedAt, event.completedAt)
        }
        // Health reflects the most recently completed real upstream work, even
        // when an older-started fetch finishes last. Same-time replacements
        // count as one observation; distinct later completion is needed to
        // establish repeated failure. UUID breaks ties for the latest outcome.
        if let updatedAt, (event.completedAt < updatedAt ||
            (event.completedAt == updatedAt && event.id <= updateID)) {
            // A delayed recovery within the known failure streak invalidates
            // earlier failures. Retain only the latest known failure as evidence.
            if event.outcome == .usableAQI, let failureStartedAt,
               event.completedAt >= failureStartedAt {
                self.failureStartedAt = updatedAt
                consecutiveFailures = 1
            }
            return
        }
        let replacesSameTimeFailure = updatedAt == event.completedAt && consecutiveFailures > 0
        updatedAt = event.completedAt
        updateID = event.id
        outcome = event.outcome
        httpStatus = event.httpStatus
        durationMilliseconds = event.durationMilliseconds
        if event.outcome == .usableAQI {
            consecutiveFailures = 0
            failureStartedAt = nil
        } else if event.attemptedAt != nil {
            if !replacesSameTimeFailure {
                consecutiveFailures = min(consecutiveFailures + 1, 1_000_000)
            }
            failureStartedAt = failureStartedAt ?? event.completedAt
        } else {
            consecutiveFailures = 0
            failureStartedAt = nil
        }
    }

    func health(at now: Date) -> OperatorDashboardHealthState {
        if outcome == .unknown { return .unknown }
        if outcome == .usableAQI { return .healthy }
        // Two failures spanning 2 x the 45-minute cache lifetime establish a
        // sustained outage; idle time never promotes transient failures.
        _ = now
        let threshold = 2 * AirQualityConfiguration.defaultCacheLifetime
        if consecutiveFailures >= 2, let failureStartedAt, let updatedAt,
           updatedAt.timeIntervalSince(failureStartedAt) >= threshold,
           lastUsableAQIAt.map({ updatedAt.timeIntervalSince($0) >= threshold }) ?? true {
            return .critical
        }
        return .warning
    }
}

struct AirNowDependencyEvent: Sendable {
    var id: String = UUID().uuidString
    let attemptedAt: Date?
    let completedAt: Date
    let outcome: AirNowDependencyOutcome
    var httpStatus: Int? = nil
    var durationMilliseconds: Int? = nil
}

protocol AirNowDependencyRecording: Sendable {
    func record(_ event: AirNowDependencyEvent) async
}

struct DatabaseAirNowDependencyRecorder: AirNowDependencyRecording {
    let database: any Database
    let logger: Logger

    func record(_ event: AirNowDependencyEvent) async {
        do { try await AirNowDependencyStore.record(event, on: database) }
        catch {
            // Never log downstream errors/URLs: they may contain the API key.
            logger.warning("AirNow operational status could not be persisted.")
        }
    }
}

enum AirNowDependencyStore {
    static func load(on database: any Database) async throws -> AirNowDependencyStatus {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        return try await sql.raw("SELECT status FROM airnow_dependency_status WHERE id = 'airnow'")
            .first(decoding: Row.self)?.status ?? .init()
    }

    static func record(_ event: AirNowDependencyEvent, on database: any Database) async throws {
        try await database.transaction { transaction in
            guard let sql = transaction as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
            }
            // Lock the sole record, including creation, across all API processes.
            try await sql.raw("SELECT pg_advisory_xact_lock(323, 1)").run()
            var status = try await load(on: transaction)
            status.apply(event)
            let json = String(decoding: try JSONEncoder().encode(status), as: UTF8.self)
            try await sql.raw("""
                INSERT INTO airnow_dependency_status (id, status)
                VALUES ('airnow', \(bind: json)::jsonb)
                ON CONFLICT (id) DO UPDATE SET status = EXCLUDED.status
                """).run()
        }
    }

    private struct Row: Decodable { let status: AirNowDependencyStatus }
}

/// Only the API advertises its configuration. Worker configuration is not
/// evidence about the API's key, and startup never performs an AirNow probe.
struct AirNowConfigurationLifecycle: LifecycleHandler {
    let configured: Bool

    func didBootAsync(_ app: Application) async throws {
        do {
            let status = try await AirNowDependencyStore.load(on: app.db)
            if !configured || status.outcome == .disabled {
                await DatabaseAirNowDependencyRecorder(database: app.db, logger: app.logger).record(.init(
                    attemptedAt: nil, completedAt: .now, outcome: configured ? .unknown : .disabled
                ))
            }
        } catch { app.logger.warning("AirNow configuration status could not be persisted.") }
    }
}

public struct AirNowDependencyMetricResponse: Content, Sendable {
    public let status: OperatorDashboardHealthState
    public let dependency: AirNowDependencyStatus
    public let summary: String

    init(metric: AirNowDependencyStatus, now: Date) {
        status = metric.health(at: now)
        dependency = metric
        summary = metric.httpStatus.map { "AirNow HTTP \($0) · \(metric.outcome.summary)" } ?? metric.outcome.summary
    }
}
