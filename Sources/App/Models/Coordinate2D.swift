//
//  Coordinate2D.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//

import Foundation

struct Coordinate2D: Sendable, Codable, Hashable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        
    }
}
