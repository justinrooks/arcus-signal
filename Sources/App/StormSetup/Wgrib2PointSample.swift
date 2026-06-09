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

    var inventoryDescriptor: Wgrib2InventoryDescriptor? {
        Wgrib2InventoryDescriptor.parse(from: inventory)
    }

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

struct Wgrib2InventoryDescriptor: Sendable, Codable, Equatable {
    let variable: String
    let level: String
    let forecastLabel: String?
    let rawInventoryPrefix: String

    static func parse(from inventory: String) -> Wgrib2InventoryDescriptor? {
        let prefix = inventory.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? inventory
        let components = prefix.split(separator: ":", omittingEmptySubsequences: false).map(String.init)

        guard components.count >= 5 else {
            return nil
        }

        let variable = components[3].trimmingCharacters(in: .whitespacesAndNewlines)
        let level = components[4].trimmingCharacters(in: .whitespacesAndNewlines)
        let forecastLabel = components.dropFirst(5).joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)

        guard !variable.isEmpty, !level.isEmpty else {
            return nil
        }

        return Wgrib2InventoryDescriptor(
            variable: variable,
            level: level,
            forecastLabel: forecastLabel.isEmpty ? nil : forecastLabel,
            rawInventoryPrefix: prefix
        )
    }
}
