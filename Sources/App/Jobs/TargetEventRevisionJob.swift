import Fluent
import Foundation
import Queues
import Vapor

public struct TargetEventRevisionPayload: Codable, Sendable {
    public let seriesId: UUID
    public let revisionUrn: String
    public let geometry: GeoShape
    public let reason: NotificationReason
    public let queuedAt: Date?
    public let targetExecutionId: UUID?

    public init(
        seriesId: UUID,
        revisionUrn: String,
        geometry: GeoShape,
        reason: NotificationReason,
        queuedAt: Date? = nil,
        targetExecutionId: UUID? = UUID()
    ) {
        self.seriesId = seriesId
        self.revisionUrn = revisionUrn
        self.geometry = geometry
        self.reason = reason
        self.queuedAt = queuedAt
        self.targetExecutionId = targetExecutionId
    }

    private enum CodingKeys: String, CodingKey {
        case seriesId
        case revisionUrn
        case geometry
        case reason
        case queuedAt
        case targetExecutionId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seriesId = try container.decode(UUID.self, forKey: .seriesId)
        self.revisionUrn = try container.decode(String.self, forKey: .revisionUrn)
        self.geometry = try container.decode(GeoShape.self, forKey: .geometry)
        self.reason = try container.decodeIfPresent(NotificationReason.self, forKey: .reason) ?? .new
        self.queuedAt = try container.decodeIfPresent(Date.self, forKey: .queuedAt)
        self.targetExecutionId = try container.decodeIfPresent(UUID.self, forKey: .targetExecutionId)
    }
}

public struct TargetEventRevisionJob: AsyncJob {
    public typealias Payload = TargetEventRevisionPayload

    private let buildCoverage: @Sendable (GeoShape) throws -> H3CoverageResult

    public init() {
        self.buildCoverage = { try H3CoverageBuilder.build(for: $0) }
    }

    init(buildCoverage: @escaping @Sendable (GeoShape) throws -> H3CoverageResult) {
        self.buildCoverage = buildCoverage
    }

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        let startedAt = Date()
        context.logger.info(
            "TargetEventRevisionJob dequeued. Begin h3 encoding",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "geometryType": .string(geometryType(payload.geometry)),
                "reason": .string(payload.reason.rawValue)
            ]
        )

        let timingStore = PipelineStageTimingStore()
        let timingOwner = await timingStore.record("target started", logger: context.logger) {
            try await timingStore.startTarget(payload, at: startedAt, on: context.application.db)
        } ?? false
        do {
            let coverage = try buildCoverage(payload.geometry)
            let result: TargetDispatchCompletionResult
            let h3CompletedAt: Date?
            switch coverage {
            case .supported(let supportedCoverage):
                context.logger.info(
                    "Computed H3 cover",
                    metadata: [
                        "seriesId": .string(payload.seriesId.uuidString),
                        "h3Count": .stringConvertible(supportedCoverage.cells.count),
                        "h3Hash": .string(supportedCoverage.h3Hash),
                        "geometryHash": .string(supportedCoverage.geometryHash)
                    ]
                )
                h3CompletedAt = try await context.application.db.transaction { database in
                    try await persistGeolocation(
                        payload,
                        coverage: supportedCoverage,
                        on: database,
                        logger: context.logger
                    )
                }
                result = .succeeded
            case .unsupportedPoint:
                context.logger.debug(
                    "No polygon geometry available; skipping H3 persistence",
                    metadata: ["seriesId": .string(payload.seriesId.uuidString)]
                )
                result = .unsupportedGeometry
                h3CompletedAt = nil
            case .coverFailure(let errorDescription):
                context.logger.warning(
                    "H3 cover computation failed; falling back to UGC notification dispatch.",
                    metadata: [
                        "seriesId": .string(payload.seriesId.uuidString),
                        "revisionUrn": .string(payload.revisionUrn),
                        "error": .string(errorDescription)
                    ]
                )
                result = .unsupportedGeometry
                h3CompletedAt = nil
            }

            if timingOwner, let h3CompletedAt {
                _ = await timingStore.record("H3 completed", logger: context.logger) {
                    try await timingStore.completeTarget(payload, h3Completed: true, at: h3CompletedAt, on: context.application.db)
                }
            }
            try await markDispatchResult(
                payload: payload,
                result: result.rawValue,
                errorMessage: nil,
                on: context.application.db
            )

            if result == .unsupportedGeometry {
                if try await DispatchAgent.enqueueNotificationDispatchOutbox(
                    revisionUrn: payload.revisionUrn,
                    seriesId: payload.seriesId,
                    reason: payload.reason,
                    mode: .ugc,
                    sourceTargetExecutionId: payload.targetExecutionId,
                    on: context.application.db,
                    logger: context.logger
                ) {
                    context.logger.info(
                        "Queued UGC fallback notification dispatch after unsupported H3 geometry.",
                        metadata: [
                            "seriesId": .string(payload.seriesId.uuidString),
                            "revisionUrn": .string(payload.revisionUrn)
                        ]
                    )
                }

                let drainUGCResult = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "ugc")
                context.logger.info(
                    "Notification dispatch outbox drain finished for ugc fallback",
                    metadata: [
                        "dispatched": .stringConvertible(drainUGCResult.dispatched),
                        "failed": .stringConvertible(drainUGCResult.failed)
                    ]
                )
                return
            }

            let drainH3Result = try await DispatchAgent.dispatchPendingNotificationJobs(context: context, mode: "h3")
            context.logger.info(
                "Notification dispatch outbox drain finished for h3",
                metadata: [
                    "dispatched": .stringConvertible(drainH3Result.dispatched),
                    "failed": .stringConvertible(drainH3Result.failed)
                ]
            )
        } catch {
            try? await markDispatchResult(
                payload: payload,
                result: TargetDispatchCompletionResult.failed.rawValue,
                errorMessage: String(reflecting: error),
                on: context.application.db
            )
            throw error
        }
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "TargetEventRevisionJob failed.",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "geometryType": .string(geometryType(payload.geometry)),
                "reason": .string(payload.reason.rawValue),
                "error": .string(String(reflecting: error))
            ]
        )
    }
}

private extension TargetEventRevisionJob {
    enum TargetDispatchCompletionResult: String {
        case succeeded
        case unsupportedGeometry = "unsupported_geometry"
        case failed
    }

    func persistGeolocation(
        _ payload: TargetEventRevisionPayload,
        coverage: H3Coverage,
        on database: any Database,
        logger: Logger
    ) async throws -> Date {
        if let existing = try await ArcusGeolocationModel.query(on: database)
            .filter(\.$series.$id == payload.seriesId)
            .first() {
            if existing.geometryHash == coverage.geometryHash
                && existing.h3Hash == coverage.h3Hash
                && existing.h3Resolution == coverage.resolution
                && existing.h3Cells == coverage.cells {
                logger.debug(
                    "Geolocation unchanged; skipping update.",
                    metadata: ["seriesId": .string(payload.seriesId.uuidString)]
                )
            } else {
                existing.geometry = payload.geometry
                existing.geometryHash = coverage.geometryHash
                existing.h3Cells = coverage.cells
                existing.h3Resolution = coverage.resolution
                existing.h3Hash = coverage.h3Hash
                try await existing.update(on: database)
                logger.info("Updated geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
            }
        } else {
            let geoRecord = ArcusGeolocationModel(
                series: payload.seriesId,
                geometry: payload.geometry,
                geometryHash: coverage.geometryHash,
                h3Cells: coverage.cells,
                h3Resolution: coverage.resolution,
                h3Hash: coverage.h3Hash
            )
            try await geoRecord.create(on: database)
            logger.info("Created geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
        }

        // Capture before exposing send intent; persist only after coverage commits.
        // Timing failures must not poison the coverage/notification-intent transaction.
        let h3CompletedAt = Date()
        if try await DispatchAgent.enqueueNotificationDispatchOutbox(
            revisionUrn: payload.revisionUrn,
            seriesId: payload.seriesId,
            reason: payload.reason,
            mode: .h3,
            sourceTargetExecutionId: payload.targetExecutionId,
            on: database,
            logger: logger
        ) {
            logger.info("Notification job queued.", metadata: ["seriesId": .stringConvertible(payload.seriesId)])
        }

        return h3CompletedAt
    }

    func markDispatchResult(
        payload: TargetEventRevisionPayload,
        result: String,
        errorMessage: String?,
        on database: any Database
    ) async throws {
        guard let row = try await ArcusTargetDispatchOutboxModel.query(on: database)
            .filter(\.$revisionUrn == payload.revisionUrn)
            .first() else {
            return
        }

        row.completed = .now
        row.result = result
        row.lastError = errorMessage
        try await row.update(on: database)
    }
    private func geometryType(_ geometry: GeoShape) -> String {
        switch geometry {
        case .point:
            return "point"
        case .polygon:
            return "polygon"
        case .multiPolygon:
            return "multiPolygon"
        }
    }
}
