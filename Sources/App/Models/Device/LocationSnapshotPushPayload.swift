//
//  LocationSnapshotPushPayload.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/23/26.
//

import Foundation
import Vapor

struct LocationSnapshotPushPayload: Content, Sendable {
    let timestamp: Date
    let accuracy: Double
    let placemarkSummary: String?
    let h3Cell: String?
    let county: String?
    let zone: String?
    let fireZone: String?
    let apnsDeviceToken: String
    let installationId: String
}
