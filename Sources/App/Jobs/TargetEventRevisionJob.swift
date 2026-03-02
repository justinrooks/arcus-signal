import Crypto
import Fluent
import Foundation
import Queues
import SwiftyH3
import Vapor

public struct TargetEventRevisionPayload: Codable, Sendable {
    public let seriesId: UUID
    public let geometry: GeoShape

    public init(seriesId: UUID, geometry: GeoShape) {
        self.seriesId = seriesId
        self.geometry = geometry
    }
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
                "geometryType": .string(geometryType(payload.geometry))
            ]
        )
        
        try await context.application.db.transaction { database in
            try await persistGeolocation(payload, on: database, logger: context.logger)
        }
        // TODO: notify that geo was created and kick off notifications?
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "TargetEventRevisionJob failed.",
            metadata: [
                "seriesId": .string(payload.seriesId.uuidString),
                "geometryType": .string(geometryType(payload.geometry)),
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
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func hashGeometry(_ geometry: GeoShape) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(geometry)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
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
