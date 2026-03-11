//
//  LocationSnapshotPushPayload.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/23/26.
//

import Foundation
import Vapor

struct LocationSnapshotPushPayload: Content, Sendable {
    let capturedAt: Date
    let locationAgeSeconds: Double
    let horizontalAccuracyMeters: Double
    let cellScheme: String
    let h3Cell: Int64?
    let h3Resolution: Int?
    let county: String?
    let zone: String?
    let fireZone: String?
    let apnsDeviceToken: String
    let installationId: UUID
    let source: String
    let auth: String
    let appVersion: String
    let buildNumber: String
    let platform: String
    let osVersion: String
    let apnsEnvironment: String
}
