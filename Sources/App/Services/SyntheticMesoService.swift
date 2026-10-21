import ArcusCore
import Fluent
import Foundation
import SQLKit
import SwiftyH3
import Vapor

/// Used only by the authenticated, development-only fixture endpoint.
struct SyntheticMesoService {
    // Fixed, valid URL also marks fixture ownership for narrow cleanup.
    static let sourceURL = URL(string: "https://example.invalid/arcus-signal/meso-test")!
    static let lifetime: TimeInterval = 15 * 60
    static let retention: TimeInterval = 24 * 60 * 60
    private let persistence: SPCMesoIngestPersistence

    init(persistence: SPCMesoIngestPersistence = .init()) {
        self.persistence = persistence
    }

    func create(h3Cell: Int64, on database: any Database, now: Date = .now) async throws -> MesoscaleDiscussionPayload {
        let cell = H3Cell(UInt64(bitPattern: h3Cell))
        guard cell.isValid, try cell.resolution == .res8 else {
            throw Abort(.badRequest, reason: "h3Cell must be a valid resolution-8 H3 cell")
        }
        let boundary = try cell.boundary.map {
            MesoscaleDiscussionCoordinate(latitude: $0.latitudeDegs, longitude: $0.longitudeDegs)
        }
        guard let first = boundary.first else {
            throw Abort(.unprocessableEntity, reason: "Cannot construct TEST meso polygon")
        }
        let coordinates = boundary + [first]
        // ArcusCore derives the UTC issue year from the actual issued date.
        let template = Self.product(number: 9000, coordinates: coordinates, now: now)
        return try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else { throw Abort(.internalServerError) }
            // Use the canonical feed lock for allocation AND acceptance. Concurrent
            // fixtures and real ingest cannot occupy an identity between these steps.
            try await sql.raw("LOCK TABLE spc_mesos IN SHARE ROW EXCLUSIVE MODE").run()
            let occupied = try await SPCMesoModel.query(on: db)
                .filter(\.$issueYear == template.issueYear)
                .filter(\.$number >= 9000).filter(\.$number <= 9999).all()
            let watermark = occupied.filter { $0.sourceURL == Self.sourceURL.absoluteString }
                .map(\.number).max() ?? 8999
            let used = Set(occupied.map(\.number))
            guard let number = (9000...9999).first(where: { $0 > watermark && !used.contains($0) }) else {
                throw Abort(.conflict, reason: "TEST meso identity range exhausted for this UTC year")
            }
            let product = Self.product(number: number, coordinates: coordinates, now: now)
            _ = try await persistence.persist([product], on: db, seenAt: now, enqueueNotifications: false)
            let stored = try await SPCMesoModel.query(on: db).filter(\.$productKey == product.productID).first()
            guard let id = stored?.id,
                  let geo = try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).first(),
                  geo.h3Resolution == 8, geo.h3Hash != nil, geo.h3Cells.contains(h3Cell) else {
                // Roll back the canonical insert if this cell cannot be represented
                // by the existing polygon validator and center-based polyfill.
                throw Abort(.unprocessableEntity, reason: "Computed TEST meso coverage does not contain requested H3 cell")
            }
            // Lazy, bounded cleanup leaves a 24-hour tap/open window. Retain the
            // newest current-year fixture as an allocation watermark even after
            // expiry; deleting it would allow a previously claimed ID to be reused.
            // Old-year watermarks can go because the issue year changes identity.
            try await SPCMesoModel.query(on: db)
                .filter(\.$sourceURL == Self.sourceURL.absoluteString)
                .filter(\.$number >= 9000).filter(\.$number <= 9999)
                .filter(\.$validEnd < now.addingTimeInterval(-Self.retention))
                .filter(\.$productKey != product.productID).delete()
            return product
        }
    }

    private static func product(number: Int, coordinates: [MesoscaleDiscussionCoordinate], now: Date) -> MesoscaleDiscussionPayload {
        MesoscaleDiscussionPayload(
            number: number, title: "TEST Mesoscale Discussion — Development Fixture", sourceURL: sourceURL,
            issued: now, validStart: now, validEnd: now.addingTimeInterval(lifetime),
            areasAffected: "TEST area — synthetic H3 coverage", summary: "TEST ONLY. No real weather threat.",
            concerning: "TEST — development fixture", watchProbability: nil,
            watchProbabilityText: "TEST — not applicable", threats: nil, coordinates: coordinates
        )
    }
}
