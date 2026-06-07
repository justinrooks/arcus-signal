//
//  Wgrib2PointSample.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation

struct Wgrib2PointRequest: Sendable {
    let fileURL: URL
    let longitude: Double
    let latitude: Double
    let matchPattern: String?
}

struct Wgrib2PointSample: Sendable, Codable, Equatable {
    let inventory: String
    let longitude: Double?
    let latitude: Double?
    let value: Double?

    static func parse(from line: String) -> Wgrib2PointSample {
        Wgrib2PointSample(
            inventory: line,
            longitude: parseDouble(in: line, token: "lon="),
            latitude: parseDouble(in: line, token: "lat="),
            value: parseDouble(in: line, token: "val=")
        )
    }

    private static func parseDouble(in line: String, token: String) -> Double? {
        guard let tokenRange = line.range(of: token) else {
            return nil
        }

        let valueSubstring = line[tokenRange.upperBound...]
        let numericSubstring = valueSubstring.prefix { character in
            !character.isWhitespace && character != ","
        }

        guard !numericSubstring.isEmpty else {
            return nil
        }

        return Double(numericSubstring)
    }
}
