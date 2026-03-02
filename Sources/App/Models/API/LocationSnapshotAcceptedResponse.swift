//
//  LocationSnapshotAcceptedResponse.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/23/26.
//

import Foundation
import Vapor

struct LocationSnapshotAcceptedResponse: Content {
    let status: String
    let receivedAt: Date
}
