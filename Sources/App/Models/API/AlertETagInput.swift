//
//  AlertETagInput.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/20/26.
//

import Foundation

struct AlertETagInput: Codable, Sendable {
    let id: UUID
    let currentRevisionUrn: String
    let contentFingerprint: String
}
