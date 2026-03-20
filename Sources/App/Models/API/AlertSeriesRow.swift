//
//  AlertSeriesRow.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/20/26.
//

import Foundation
import Fluent
import FluentSQL

struct AlertSeriesRow: Decodable, Sendable {
    let id: UUID
    let event: String
    let currentRevisionUrn: String
    let currentRevisionSent: Date?
    let messageType: String
    let contentFingerprint: String
    let state: String
    let created: Date
    let updated: Date
    let lastSeenActive: Date
    let sent: Date?
    let effective: Date?
    let onset: Date?
    let expires: Date?
    let ends: Date?
    let severity: String
    let urgency: String
    let certainty: String
    let areaDesc: String?
    let senderName: String?
    let headline: String?
    let description: String?
    let instructions: String?
    let response: String?
    let ugcCodes: [String]
    let h3Cells: [Int64]

    func asDeviceAlertPayload() -> DeviceAlertPayload {
        .init(
            id: id,
            event: event,
            currentRevisionUrn: currentRevisionUrn,
            currentRevisionSent: currentRevisionSent,
            messageType: messageType,
            state: state,
            created: created,
            updated: updated,
            lastSeenActive: lastSeenActive,
            sent: sent,
            effective: effective,
            onset: onset,
            expires: expires,
            ends: ends,
            severity: severity,
            urgency: urgency,
            certainty: certainty,
            areaDesc: areaDesc,
            senderName: senderName,
            headline: headline,
            description: description,
            instructions: instructions,
            response: response,
            ugc: ugcCodes,
            h3Cells: h3Cells
        )
    }
}

extension AlertSeriesRow {
    static func sqlSelectColumns(
        seriesAlias: String = "s",
        geolocationAlias: String = "g"
    ) -> SQLQueryString {
        [
            "\(ident: seriesAlias).\(ident: "id") AS \(ident: "id")",
            "\(ident: seriesAlias).\(ident: "event") AS \(ident: "event")",
            "\(ident: seriesAlias).\(ident: "current_revision_urn") AS \(ident: "currentRevisionUrn")",
            "\(ident: seriesAlias).\(ident: "current_revision_sent") AS \(ident: "currentRevisionSent")",
            "\(ident: seriesAlias).\(ident: "message_type") AS \(ident: "messageType")",
            "\(ident: seriesAlias).\(ident: "content_fingerprint") AS \(ident: "contentFingerprint")",
            "\(ident: seriesAlias).\(ident: "state") AS \(ident: "state")",
            "\(ident: seriesAlias).\(ident: "created") AS \(ident: "created")",
            "\(ident: seriesAlias).\(ident: "updated") AS \(ident: "updated")",
            "\(ident: seriesAlias).\(ident: "last_seen_active") AS \(ident: "lastSeenActive")",
            "\(ident: seriesAlias).\(ident: "sent") AS \(ident: "sent")",
            "\(ident: seriesAlias).\(ident: "effective") AS \(ident: "effective")",
            "\(ident: seriesAlias).\(ident: "onset") AS \(ident: "onset")",
            "\(ident: seriesAlias).\(ident: "expires") AS \(ident: "expires")",
            "\(ident: seriesAlias).\(ident: "ends") AS \(ident: "ends")",
            "\(ident: seriesAlias).\(ident: "severity") AS \(ident: "severity")",
            "\(ident: seriesAlias).\(ident: "urgency") AS \(ident: "urgency")",
            "\(ident: seriesAlias).\(ident: "certainty") AS \(ident: "certainty")",
            "\(ident: seriesAlias).\(ident: "area_desc") AS \(ident: "areaDesc")",
            "\(ident: seriesAlias).\(ident: "sender_name") AS \(ident: "senderName")",
            "\(ident: seriesAlias).\(ident: "headline") AS \(ident: "headline")",
            "\(ident: seriesAlias).\(ident: "description") AS \(ident: "description")",
            "\(ident: seriesAlias).\(ident: "instructions") AS \(ident: "instructions")",
            "\(ident: seriesAlias).\(ident: "response") AS \(ident: "response")",
            "\(ident: seriesAlias).\(ident: "ugc_codes") AS \(ident: "ugcCodes")",
            "COALESCE(\(ident: geolocationAlias).\(ident: "h3_cells"), '{}'::bigint[]) AS \(ident: "h3Cells")"
        ]
        .joined(separator: ",\n")
    }

    var etagInput: AlertETagInput {
        .init(
            id: id,
            currentRevisionUrn: currentRevisionUrn,
            contentFingerprint: contentFingerprint
        )
    }
}
