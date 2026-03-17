import Fluent
import Foundation
import Queues
import SwiftyH3
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

private struct DispatchDrainResult {
    let dispatched: Int
    let failed: Int
}

public struct TargetEventRevisionJob: AsyncJob {
    private let h3Resolution: Int16 = 8
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
        
        try await context.application.db.transaction { database in
            try await persistGeolocation(payload, on: database, logger: context.logger)
        }
        
        let drainNotificationsResult = try await dispatchPendingNotificationJobs(context: context)
        context.logger.info(
            "Notification dispatch outbox drain finished for h3",
            metadata: [
                "dispatched": .stringConvertible(drainNotificationsResult.dispatched),
                "failed": .stringConvertible(drainNotificationsResult.failed)
            ]
        )
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
    func persistGeolocation(
        _ payload: TargetEventRevisionPayload,
        on database: any Database,
        logger: Logger
    ) async throws {
        let cover = try buildH3Cover(for: payload.geometry)

        guard let cover else {
            logger.debug(
                "No polygon geometry available; skipping H3 persistence",
                metadata: ["seriesId": .string(payload.seriesId.uuidString)]
            )
            return
        }

        let geometryHash = try hashGeometry(payload.geometry)

        logger.info(
            "Computed H3 cover",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "h3Count": .stringConvertible(cover.cells.count),
                "h3Hash": .string(cover.hash),
                "geometryHash": .string(geometryHash)
            ]
        )

        if let existing = try await ArcusGeolocationModel.query(on: database)
            .filter(\.$series.$id == payload.seriesId)
            .first() {
            if existing.geometryHash == geometryHash
                && existing.h3Hash == cover.hash
                && existing.h3Resolution == h3Resolution
                && existing.h3Cells == cover.cells {
                logger.debug(
                    "Geolocation unchanged; skipping update.",
                    metadata: ["seriesId": .string(payload.seriesId.uuidString)]
                )
                return
            }

            existing.geometry = payload.geometry
            existing.geometryHash = geometryHash
            existing.h3Cells = cover.cells
            existing.h3Resolution = h3Resolution
            existing.h3Hash = cover.hash
            try await existing.update(on: database)
            logger.info("Updated geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
            return
        }

        let geoRecord = ArcusGeolocationModel(
            series: payload.seriesId,
            geometry: payload.geometry,
            geometryHash: geometryHash,
            h3Cells: cover.cells,
            h3Resolution: h3Resolution,
            h3Hash: cover.hash
        )
        try await geoRecord.create(on: database)
        logger.info("Created geolocation cover", metadata: ["seriesId": .string(payload.seriesId.uuidString)])
        
        if try await enqueueNotificationDispatchOutbox(
            revisionUrn: payload.revisionUrn,
            seriesId: payload.seriesId,
            reason: payload.reason,
            on: database,
            logger: logger
        ) {
//            notificationOutboxQueued += 1
            logger.info("Notification job queued.", metadata: ["seriesId": .stringConvertible(payload.seriesId)])
        }
    }
    
    func enqueueNotificationDispatchOutbox(
        revisionUrn: String,
        seriesId: UUID,
        reason: NotificationReason,
        on database: any Database,
        logger: Logger
    ) async throws -> Bool {
        // TODO: resolve the dupe with IngestNWSAlertsJob
        let outboxRecord = ArcusNotificationOutboxModel(
            series: seriesId,
            revisionUrn: revisionUrn,
            mode: NotificationTargetMode.h3.rawValue,
            reason: reason.rawValue,
            state: "ready",
            attempts: 0,
            availableAt: .now
        )
        
        do {
            try await outboxRecord.create(on: database)
            return true
        } catch {
            if isUniqueConstraintViolation(error) {
                logger.debug(
                    "Notification dispatch already queued for revision.",
                    metadata: ["revisionUrn": .string(revisionUrn)]
                )
                return false
            }

            throw error
        }
    }
    
    func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        // TODO: resolve the dupe with IngestNWSAlertsJob
        let description = String(describing: error).lowercased()
        return description.contains("duplicate key value")
        || description.contains("unique constraint")
        || description.contains("23505")
    }
    
    func dispatchPendingNotificationJobs(
        context: QueueContext,
        limit: Int = 250
    ) async throws -> DispatchDrainResult {
        // TODO: resolve the dupe with IngestNWSAlertsJob
        let pendingRows = try await ArcusNotificationOutboxModel.query(on: context.application.db)
            .group(.and) { group in
                group.filter(\.$state == "ready")
                     .filter(\.$mode == "h3") // Lock this dispatcher to only send ready h3 notification msgs
            }
            .sort(\.$created, .ascending)
            .limit(limit)
            .all()

        guard !pendingRows.isEmpty else {
            return .init(dispatched: 0, failed: 0)
        }

        let sendQueue = context.application.queues.queue(ArcusQueueLane.send.queueName)
        var dispatched = 0
        var failed = 0

        for row in pendingRows {
            do {
                guard let mode = NotificationTargetMode(rawValue: row.mode) else {
                    throw ArcusEventModelError.invalidEnum(field: "mode", value: row.mode)
                }
                guard let reason = NotificationReason(rawValue: row.reason) else {
                    throw ArcusEventModelError.invalidEnum(field: "reason", value: row.reason)
                }
                
                let pl: NotificationSendJobPayload = .init(
                    seriesId: row.$series.id,
                    revisionUrn: row.revisionUrn,
                    mode: mode,
                    reason: reason
                )
                
                try await sendQueue.dispatch(NotificationSendJob.self, pl)
                row.availableAt = Date()
                row.lastError = nil
                row.attempts += 1
                row.state = "done" // Mark as done since we've sent it to the queue
                
                try await row.update(on: context.application.db)
                dispatched += 1
            } catch {
                failed += 1
                row.attempts += 1
                row.lastError = String(reflecting: error)
                
                if row.attempts >= 3 {
                    row.state = "dead" // Mark is as dead after 3 retries
                }
                
                try? await row.update(on: context.application.db)

                context.logger.error(
                    "Failed to dispatch notifcation job from outbox h3",
                    metadata: [
                        "outboxId": .string(row.id?.uuidString ?? "unknown"),
                        "revisionUrn": .string(row.revisionUrn),
                        "error": .string(String(reflecting: error))
                    ]
                )
            }
        }

        return .init(dispatched: dispatched, failed: failed)
    }
    
    // MARK: H3 HASHING
    private func buildH3Cover(
        for geometry: GeoShape
    ) throws -> (cells: [Int64], hash: String)? {
        switch geometry {
        case .point:
            return nil
        case .polygon(let rings):
            let cells = try h3Cells(for: rings)
            let sorted = Array(Set(cells)).sorted()
            return (sorted, hashCells(sorted))
        case .multiPolygon(let polygons):
            var mergedCells: Set<Int64> = []
            for polygon in polygons {
                let polygonCells = try h3Cells(for: polygon)
                mergedCells.formUnion(polygonCells)
            }
            let sorted = Array(mergedCells).sorted()
            return (sorted, hashCells(sorted))
        }
    }

    private func h3Cells(
        for rings: [[GeoShape.GeoCoordinate]]
    ) throws -> [Int64] {
        guard let boundaryRing = rings.first, !boundaryRing.isEmpty else {
            throw SwiftyH3Error.invalidInput
        }
        let boundary: H3Loop = boundaryRing.map { coordinate in
            H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
        }
        
        let holes: [H3Loop] = rings.dropFirst().map { holeRing in
            holeRing.map { coordinate in
                H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
            }
        }
        
        let polygon = H3Polygon(boundary, holes: holes)
        let resolution = H3Cell.Resolution(rawValue: Int32(h3Resolution)) ?? .res8
        let cells = try polygon.cells(at: resolution)
        return cells.map { Int64(bitPattern: $0.id) }
    }

    private func hashCells(_ sortedCells: [Int64]) -> String {
        var data = Data(capacity: sortedCells.count * MemoryLayout<UInt64>.size)
        for v in sortedCells {
            var u = UInt64(bitPattern: v).bigEndian
            withUnsafeBytes(of: &u) { data.append(contentsOf: $0) }
        }
        return StableContentHasher.sha256Hex(of: data)
    }

    private func hashGeometry(_ geometry: GeoShape) throws -> String {
        try StableContentHasher.sha256Hex(of: geometry, dateEncodingStrategy: .deferredToDate)
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
