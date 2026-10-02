import Fluent
import Foundation
import SQLKit
import Vapor

/// First execution boundaries only. An incomplete first execution stays incomplete;
/// replay must not manufacture a duration spanning multiple processing attempts.
struct PipelineStageTimingStore {
    /// Auxiliary operational evidence must never become delivery authority.
    func record<T>(_ boundary: String, logger: Logger, operation: () async throws -> T) async -> T? {
        do {
            return try await operation()
        } catch {
            logger.warning("Failed to persist pipeline stage timing", metadata: [
                "boundary": .string(boundary), "error": .string(String(reflecting: error))
            ])
            return nil
        }
    }

    func startTarget(_ payload: TargetEventRevisionPayload, at now: Date = .now, on db: any Database) async throws -> Bool {
        guard let executionID = payload.targetExecutionId else { return false }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let row = try await sql.raw("""
            INSERT INTO target_pipeline_timings (execution_id, revision_urn, series_id, queued_at, started_at)
            SELECT \(bind: executionID), \(bind: payload.revisionUrn), \(bind: payload.seriesId), \(bind: payload.queuedAt), \(bind: now)
            WHERE NOT EXISTS (
                SELECT 1 FROM target_dispatch_outbox
                WHERE revision_urn = \(bind: payload.revisionUrn) AND completed IS NOT NULL
            )
            ON CONFLICT (execution_id) DO NOTHING RETURNING execution_id
            """).first()
        return row != nil
    }

    func completeTarget(_ payload: TargetEventRevisionPayload, h3Completed: Bool, at now: Date = .now, on db: any Database) async throws {
        guard h3Completed, let executionID = payload.targetExecutionId else { return } // UGC fallback has no completed H3 stage.
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            UPDATE target_pipeline_timings SET h3_completed_at = \(bind: now)
            WHERE execution_id = \(bind: executionID) AND revision_urn = \(bind: payload.revisionUrn) AND series_id = \(bind: payload.seriesId)
              AND h3_completed_at IS NULL
            """).run()
    }

    func startNotification(_ payload: NotificationSendJobPayload, at now: Date = .now, on db: any Database) async throws -> Bool {
        guard payload.origin == .alertDriven, payload.installationId == nil,
              let attemptID = payload.deliveryAttemptId else { return false }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let row = try await sql.raw("""
            INSERT INTO notification_pipeline_timings
                (delivery_attempt_id, series_id, revision_urn, mode, queued_at, started_at, source_target_execution_id)
            VALUES (\(bind: attemptID), \(bind: payload.seriesId), \(bind: payload.revisionUrn),
                    \(bind: payload.mode.rawValue), \(bind: payload.queuedAt), \(bind: now), \(bind: payload.sourceTargetExecutionId))
            ON CONFLICT (delivery_attempt_id) DO NOTHING RETURNING delivery_attempt_id
            """).first()
        return row != nil
    }

    func completeCandidateResolution(
        _ payload: NotificationSendJobPayload,
        candidateCount: Int,
        at now: Date = .now,
        on db: any Database
    ) async throws {
        guard payload.origin == .alertDriven, payload.installationId == nil,
              let attemptID = payload.deliveryAttemptId else { return }
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("""
            UPDATE notification_pipeline_timings
            SET candidate_resolution_completed_at = \(bind: now), candidate_count = \(bind: candidateCount)
            WHERE delivery_attempt_id = \(bind: attemptID) AND series_id = \(bind: payload.seriesId)
              AND revision_urn = \(bind: payload.revisionUrn) AND mode = \(bind: payload.mode.rawValue)
              AND candidate_resolution_completed_at IS NULL AND candidate_count IS NULL
            """).run()
    }
}
