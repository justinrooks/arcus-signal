//
//  ext+Double.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//

import Foundation

extension Double {
    func truncated(to places: Int) -> Double {
        let factor = Double.pow(10.0, Double(places))
        return (self * factor).rounded(.towardZero) / factor
    }
}
