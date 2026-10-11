import ArcusCore
import Fluent
import Foundation
import SQLKit
import Vapor

struct SPCMesoPersistResult: Sendable {
    var inserted = 0
    var updated = 0
    var unchanged = 0
    var ignored = 0
}

/// Accepted feeds are additive. Expiry is derived from validity, never feed absence.
struct SPCMesoIngestPersistence {
    private let buildCoverage: @Sendable (GeoShape) throws -> H3Coverage

    init(buildCoverage: @escaping @Sendable (GeoShape) throws -> H3Coverage = { try SPCMesoCoverage.build(for: $0) }) {
        self.buildCoverage = buildCoverage
    }

    func persistFeed(_ data: Data, on database: any Database, seenAt: Date) async throws -> SPCMesoPersistResult {
        // Reject the entire feed before opening a transaction or changing lastSeen.
        try await persist(SPCMesoParser.parse(data), on: database, seenAt: seenAt)
    }

    func persist(
        _ products: [MesoscaleDiscussionPayload], on database: any Database, seenAt: Date
    ) async throws -> SPCMesoPersistResult {
        var accepted: [String: MesoscaleDiscussionPayload] = [:]
        for product in products {
            guard product.validStart < product.validEnd,
                  accepted[product.productID] == nil || accepted[product.productID] == product else {
                throw SPCMesoError.malformedDiscussion(product.productID)
            }
            accepted[product.productID] = product
        }
        let snapshots = try accepted.values.sorted { $0.productID < $1.productID }.map {
            (product: $0, fingerprint: try StableContentHasher.sha256Hex(of: $0))
        }
        return try await database.transaction { db in
            guard let sql = db as? any SQLDatabase else {
                throw Abort(.internalServerError, reason: "SPC meso persistence requires PostgreSQL.")
            }
            // Serialize feed writes, including first insert, across processes. The
            // transaction-scoped lock avoids check/create races and lost snapshots.
            try await sql.raw("LOCK TABLE spc_mesos IN SHARE ROW EXCLUSIVE MODE").run()
            var result = SPCMesoPersistResult()
            for snapshot in snapshots {
                let product = snapshot.product
                let meso: SPCMesoModel
                if let stored = try await SPCMesoModel.query(on: db)
                    .filter(\.$productKey == product.productID).first() {
                    meso = stored
                    if stored.contentFingerprint == snapshot.fingerprint {
                        stored.lastSeen = max(stored.lastSeen, seenAt)
                        try await stored.update(on: db)
                        result.unchanged += 1
                    } else {
                        // Observation time orders accepted snapshots. Equal-time
                        // conflicts choose the lexicographically larger fingerprint
                        // so writer/lock order cannot decide the canonical content.
                        // Match PostgresNIO's timestamp encoding; stored Date values
                        // are decoded microseconds, so recover their integer key.
                        let epoch = Date(timeIntervalSince1970: 946_684_800)
                        let incomingTime = (seenAt.timeIntervalSince(epoch) * 1_000_000).rounded(.towardZero)
                        let storedTime = (stored.lastSeen.timeIntervalSince(epoch) * 1_000_000).rounded()
                        guard incomingTime > storedTime ||
                            (incomingTime == storedTime && snapshot.fingerprint > stored.contentFingerprint) else {
                            result.ignored += 1
                            continue
                        }
                        stored.applySnapshot(product: product, contentFingerprint: snapshot.fingerprint)
                        stored.lastSeen = max(stored.lastSeen, seenAt)
                        try await stored.update(on: db)
                        result.updated += 1
                    }
                } else {
                    meso = SPCMesoModel(product: product, contentFingerprint: snapshot.fingerprint, seenAt: seenAt)
                    try await meso.create(on: db)
                    result.inserted += 1
                }
                let id = try meso.requireID()
                let existing = try await SPCMesoGeolocationModel.query(on: db).filter(\.$meso.$id == id).first()
                if product.coordinates.isEmpty {
                    try await existing?.delete(on: db)
                    continue
                }
                let geometry = GeoShape.polygon(rings: [product.coordinates.map {
                    .init(lon: $0.longitude, lat: $0.latitude)
                }])
                let geometryHash = try StableContentHasher.sha256Hex(of: geometry)
                // Replays also fill coverage for rows accepted before H3 support.
                // The canonical feed lock serializes coverage with snapshot replacement.
                if let existing, existing.geometryHash == geometryHash,
                   existing.h3Resolution == 8, existing.h3Hash != nil {
                    continue
                }
                let coverage: H3Coverage
                do {
                    coverage = try buildCoverage(geometry)
                } catch {
                    throw Abort(.unprocessableEntity, reason: "SPC meso H3 coverage failed for \(product.productID): \(String(reflecting: error))")
                }
                let location = existing ?? SPCMesoGeolocationModel(mesoID: id, geometry: geometry, geometryHash: geometryHash)
                location.geometry = geometry
                location.geometryHash = coverage.geometryHash
                location.h3Cells = coverage.cells
                location.h3Resolution = coverage.resolution
                location.h3Hash = coverage.h3Hash
                if existing != nil {
                    try await location.update(on: db)
                } else {
                    try await location.create(on: db)
                }
            }
            return result
        }
    }
}
