import ArcusCore
import FluentSQL
import SwiftyH3
import Vapor

private struct MesoLookupQuery: Content {
    let id: String?
    let h3: String?
}

struct MesosController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "mesos").get(use: index)
        }
    }

    func index(req: Request) async throws -> Response {
        let query = try req.query.decode(MesoLookupQuery.self)
        if query.id != nil && query.h3 != nil {
            throw Abort(.badRequest, reason: "id cannot be combined with h3")
        }
        if let id = query.id {
            guard id.range(of: #"^SPC-MD-[0-9]{4}-(0|[1-9][0-9]{0,3})$"#, options: .regularExpression) != nil else {
                throw Abort(.badRequest, reason: "id must use SPC-MD-<four-digit issue year>-<MD number> without number padding")
            }
        }
        var h3: Int64?
        if let raw = query.h3 {
            guard let value = Int64(raw), value > 0 else {
                throw Abort(.badRequest, reason: "h3 must be a valid resolution-8 cell encoded as a signed 64-bit integer")
            }
            let cell = H3Cell(UInt64(value))
            guard cell.isValid, try cell.resolution == .res8 else {
                throw Abort(.badRequest, reason: "h3 must be a valid resolution-8 cell")
            }
            h3 = value
        }
        guard let sql = req.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        let payload = try await loadMesos(sql: sql, productID: query.id, h3: h3, evaluatedAt: Date())
        if query.id != nil && payload.isEmpty { throw Abort(.notFound, reason: "Unknown meso product") }

        // Match alerts' default JSONEncoder date representation and hash exactly
        // the emitted body, including geometry, with deterministic key ordering.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        let etag = "W/\"\(StableContentHasher.sha256Hex(of: data))\""
        let matches = req.headers[.ifNoneMatch].joined(separator: ",").split(separator: ",").contains {
            let tag = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return tag == "*" || tag == etag || tag == String(etag.dropFirst(2))
        }
        let response = Response(status: matches ? .notModified : .ok)
        response.headers.replaceOrAdd(name: .eTag, value: etag)
        if !matches {
            response.headers.contentType = .json
            response.body = .init(data: data)
        }
        return response
    }
}

func loadMesos(
    sql: any SQLDatabase,
    productID: String?,
    h3: Int64?,
    evaluatedAt: Date
) async throws -> [MesoscaleDiscussionPayload] {
    var clauses: [SQLQueryString] = []
    if let productID {
        clauses.append("s.product_key = \(bind: productID)")
    } else {
        clauses.append("s.valid_start <= \(bind: evaluatedAt) AND s.valid_end > \(bind: evaluatedAt)")
        if let h3 {
            clauses.append("g.h3_resolution = 8 AND \(bind: h3) = ANY(g.h3_cells)")
        }
    }
    // One statement keeps canonical snapshot and geometry coherent across ingest.
    let rows = try await sql.raw("""
        SELECT
            s.md_number AS "number",
            s.issued AS "issued",
            s.valid_start AS "validStart",
            s.valid_end AS "validEnd",
            s.title AS "title",
            s.source_url AS "sourceURL",
            s.areas_affected AS "areasAffected",
            s.summary AS "summary",
            s.concerning AS "concerning",
            s.watch_probability AS "watchProbability",
            s.watch_probability_text AS "watchProbabilityText",
            s.peak_wind_mph AS "peakWindMPH",
            s.hail_range_inches AS "hailRangeInches",
            s.tornado_strength AS "tornadoStrength",
            g.geometry AS geometry
        FROM spc_mesos AS s
        LEFT JOIN spc_meso_geolocation AS g ON g.meso_id = s.id
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY s.issued DESC, s.product_key ASC
        """).all(decoding: MesoReadRow.self)
    return try rows.map { try $0.payload() }
}

private struct MesoReadRow: Decodable {
    let number: Int
    let issued: Date
    let validStart: Date
    let validEnd: Date
    let title: String
    let sourceURL: String
    let areasAffected: String
    let summary: String
    let concerning: String?
    let watchProbability: Double?
    let watchProbabilityText: String
    let peakWindMPH: Int?
    let hailRangeInches: Double?
    let tornadoStrength: String?
    let geometry: GeoShape?

    func payload() throws -> MesoscaleDiscussionPayload {
        guard let url = URL(string: sourceURL) else {
            throw Abort(.internalServerError, reason: "Invalid stored meso source URL")
        }
        let coordinates: [MesoscaleDiscussionCoordinate]
        switch geometry {
        case .polygon(let rings):
            coordinates = (rings.first ?? []).map { .init(latitude: $0.lat, longitude: $0.lon) }
        case nil:
            coordinates = []
        default:
            throw Abort(.internalServerError, reason: "Unsupported stored meso geometry")
        }
        let threats = peakWindMPH != nil || hailRangeInches != nil || tornadoStrength != nil
            ? MesoscaleDiscussionThreats(peakWindMPH: peakWindMPH, hailRangeInches: hailRangeInches, tornadoStrength: tornadoStrength)
            : nil
        return MesoscaleDiscussionPayload(
            number: number, title: title, sourceURL: url, issued: issued,
            validStart: validStart, validEnd: validEnd, areasAffected: areasAffected,
            summary: summary, concerning: concerning, watchProbability: watchProbability,
            watchProbabilityText: watchProbabilityText, threats: threats, coordinates: coordinates
        )
    }
}
