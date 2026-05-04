//
//  AlertsController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/28/26.
//

import Fluent
import FluentSQL
import Vapor

private struct AlertLookupQueryV1: Content {
    let ugc: String?
    let fire: String?
    let h3: Int64?
}

private struct AlertLookupQueryV2: Content {
    let county: String?
    let forecast: String?
    let fire: String?
    let h3: Int64?
}

struct AlertsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("api", "v1", "alerts").get(use: indexV1)
        routes.grouped("api", "v2", "alerts").get(use: indexV2)
    }

    func indexV1(req: Request) async throws -> Response {
        let query = try req.query.decode(AlertLookupQueryV1.self)
        let rows = try await loadAlertSeriesV1(matching: query, on: req.db)
        return try encodePayloadResponse(rows: rows)
    }

    func indexV2(req: Request) async throws -> Response {
        let query = try req.query.decode(AlertLookupQueryV2.self)
        let rows = try await loadAlertSeriesV2(matching: query, on: req.db)
        return try encodePayloadResponse(rows: rows)
    }

    private func encodePayloadResponse(rows: [AlertSeriesRow]) throws -> Response {
        let payload = rows.map { $0.asDeviceAlertPayload() }
        let response = Response(status: .ok)
        try response.content.encode(payload)
        return response
    }
}

private func loadAlertSeriesV1(
    matching query: AlertLookupQueryV1,
    on database: any Database
) async throws -> [AlertSeriesRow] {
    guard let sql = database as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
    }

    if let h3 = query.h3, h3 <= 0 {
        throw Abort(.badRequest, reason: "h3 must be > 0 when provided")
    }

    let ugcCodes = uniqueUGCCodes([query.ugc, query.fire])

    guard !ugcCodes.isEmpty || query.h3 != nil else {
        throw Abort(.badRequest, reason: "At least one of ugc, fire, or h3 is required")
    }

    return try await loadAlertSeries(sql: sql, ugcCodes: ugcCodes, h3: query.h3)
}

private func loadAlertSeriesV2(
    matching query: AlertLookupQueryV2,
    on database: any Database
) async throws -> [AlertSeriesRow] {
    guard let sql = database as? any SQLDatabase else {
        throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
    }

    if let h3 = query.h3, h3 <= 0 {
        throw Abort(.badRequest, reason: "h3 must be > 0 when provided")
    }

    let ugcCodes = uniqueUGCCodes([query.county, query.forecast, query.fire])

    guard !ugcCodes.isEmpty || query.h3 != nil else {
        throw Abort(.badRequest, reason: "At least one of county, forecast, fire, or h3 is required")
    }

    return try await loadAlertSeries(sql: sql, ugcCodes: ugcCodes, h3: query.h3)
}

private func loadAlertSeries(
    sql: any SQLDatabase,
    ugcCodes: [String],
    h3: Int64?
) async throws -> [AlertSeriesRow] {

    var matchClauses: [SQLQueryString] = ugcCodes.map { code in
        "\(bind: code) = ANY(\(ident: "s").\(ident: "ugc_codes"))"
    }

    if let h3 {
        matchClauses.append(
            "\(bind: h3) = ANY(COALESCE(\(ident: "g").\(ident: "h3_cells"), '{}'::bigint[]))"
        )
    }

    // TODO: Investigate this more. Removing the filter for state = active and replaced it
    // it was replaced with state <> cancelled in error. We want to send all the watches
    // and warnings we have to the device and let the device determine display. It is at
    // the edge and has the most accurate knowledge of time and location, so allow it to
    // do its job and determine if the alert should be shown. We have different issues if
    // its a cancelled in error state.
    return try await sql.raw("""
        SELECT \(AlertSeriesRow.sqlSelectColumns())
        FROM \(ident: ArcusSeriesModel.schema) AS \(ident: "s")
        LEFT JOIN \(ident: ArcusGeolocationModel.schema) AS \(ident: "g")
          ON \(ident: "g").\(ident: "series_id") = \(ident: "s").\(ident: "id")
        WHERE \(ident: "s").\(ident: "state") <> \(bind: EventState.cancelled_in_error.rawValue)
          AND (\(matchClauses.joined(separator: " OR ")))
        ORDER BY \(ident: "s").\(ident: "ends") DESC NULLS LAST,
                 \(ident: "s").\(ident: "sent") DESC NULLS LAST,
                 \(ident: "s").\(ident: "id") ASC
        """)
        .all(decoding: AlertSeriesRow.self)
}

private func uniqueUGCCodes(_ values: [String?]) -> [String] {
    var seenUGCCodes = Set<String>()
    return values
        .map(normalizedUGCCode)
        .compactMap { $0 }
        .filter { seenUGCCodes.insert($0).inserted }
}

private func normalizedUGCCode(_ value: String?) -> String? {
    normalizedOptional(value)?.uppercased()
}

private func computeAlertsETag(for series: [AlertSeriesRow]) throws -> String {
    let etagInput = series
        .map(\.etagInput)
        .sorted {
            if $0.id != $1.id {
                return $0.id.uuidString < $1.id.uuidString
            }

            return $0.currentRevisionUrn < $1.currentRevisionUrn
        }

    return try StableContentHasher.weakETag(of: etagInput)
}

private func etagMatches(_ ifNoneMatch: String?, currentETag: String) -> Bool {
    guard let ifNoneMatch else { return false }

    return ifNoneMatch
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .contains(currentETag)
}
