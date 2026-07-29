import Fluent
import Foundation
import Queues
import Vapor

public struct TargetEventRevisionPayload: Codable, Sendable {
    public let seriesId: UUID
    public let revisionUrn: String
    public let geometry: GeoShape
    public let reason: NotificationReason

    public init(
        seriesId: UUID,
        revisionUrn: String,
        geometry: GeoShape,
        reason: NotificationReason
    ) {
        self.seriesId = seriesId
        self.revisionUrn = revisionUrn
        self.geometry = geometry
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey {
        case seriesId
        case revisionUrn
        case geometry
        case reason
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seriesId = try container.decode(UUID.self, forKey: .seriesId)
        self.revisionUrn = try container.decode(String.self, forKey: .revisionUrn)
        self.geometry = try container.decode(GeoShape.self, forKey: .geometry)
        self.reason = try container.decodeIfPresent(NotificationReason.self, forKey: .reason) ?? .new
    }
}

public struct TargetEventRevisionJob: AsyncJob {
    public typealias Payload = TargetEventRevisionPayload

    public init() {}

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info(
            "TargetEventRevisionJob dequeued. Begin h3 encoding",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "geometryType": .string(geometryType(payload.geometry)),
                "reason": .string(payload.reason.rawValue)
            ]
        )

        do {
            let result = try await context.application.db.transaction { database in
                try await persistGeolocation(payload, on: database, logger: context.logger)
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
        on database: any Database,
        logger: Logger
    ) async throws -> TargetDispatchCompletionResult {
        let coverage = try H3CoverageBuilder.build(for: payload.geometry)
        let cover: H3Coverage
        switch coverage {
        case .supported(let supportedCoverage):
            cover = supportedCoverage
        case .unsupportedPoint:
            logger.debug(
                "No polygon geometry available; skipping H3 persistence",
                metadata: ["seriesId": .string(payload.seriesId.uuidString)]
            )
            return .unsupportedGeometry
        case .coverFailure(let errorDescription):
            logger.warning(
                "H3 cover computation failed; falling back to UGC notification dispatch.",
                metadata: [
                    "seriesId": .string(payload.seriesId.uuidString),
                    "revisionUrn": .string(payload.revisionUrn),
                    "error": .string(errorDescription)
                ]
            )
            return .unsupportedGeometry
        }

        logger.info(
            "Computed H3 cover",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "h3Count": .stringConvertible(cover.cells.count),
                "h3Hash": .string(cover.h3Hash),
                "geometryHash": .string(cover.geometryHash)
            ]
        )

        if let existing = try await ArcusGeolocationModel.query(on: database)
            .filter(\.$series.$id == payload.seriesId)
            .first() {
            if existing.geometryHash == cover.geometryHash
                && existing.h3Hash == cover.h3Hash
                && existing.h3Resolution == cover.resolution
                && existing.h3Cells == cover.cells {
                logger.debug(
                    "Geolocation unchanged; skipping update.",
                    metadata: ["seriesId": .string(payload.seriesId.uuidString)]
                )
            } else {
                existing.geometry = payload.geometry
                existing.geometryHash = cover.geometryHash
                existing.h3Cells = cover.cells
                existing.h3Resolution = cover.resolution
                existing.h3Hash = cover.h3Hash
                try await existing.update(on: database)
                logger.info("Updated geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
            }
        } else {
            let geoRecord = ArcusGeolocationModel(
                series: payload.seriesId,
                geometry: payload.geometry,
                geometryHash: cover.geometryHash,
                h3Cells: cover.cells,
                h3Resolution: cover.resolution,
                h3Hash: cover.h3Hash
            )
            try await geoRecord.create(on: database)
            logger.info("Created geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
        }

        if try await DispatchAgent.enqueueNotificationDispatchOutbox(
            revisionUrn: payload.revisionUrn,
            seriesId: payload.seriesId,
            reason: payload.reason,
            mode: .h3,
            on: database,
            logger: logger
        ) {
            logger.info("Notification job queued.", metadata: ["seriesId": .stringConvertible(payload.seriesId)])
        }

        return .succeeded
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
