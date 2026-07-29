import Foundation
import SwiftyH3

enum H3CoverageResult: Sendable, Equatable {
    case supported(H3Coverage)
    case unsupportedPoint
    case coverFailure(errorDescription: String)
}

struct H3Coverage: Sendable, Equatable {
    let cells: [Int64]
    let h3Hash: String
    let geometryHash: String
    let resolution: Int16
}

enum H3CoverageBuilder {
    private static let resolution: Int16 = 8

    static func build(for geometry: GeoShape) throws -> H3CoverageResult {
        let coveredCells: [Int64]
        switch geometry {
        case .point:
            return .unsupportedPoint
        case .polygon(let rings):
            do {
                coveredCells = try cells(for: rings)
            } catch {
                return .coverFailure(errorDescription: String(reflecting: error))
            }
        case .multiPolygon(let polygons):
            do {
                var mergedCells: Set<Int64> = []
                for polygon in polygons {
                    mergedCells.formUnion(try cells(for: polygon))
                }
                coveredCells = Array(mergedCells)
            } catch {
                return .coverFailure(errorDescription: String(reflecting: error))
            }
        }

        let sortedCells = Array(Set(coveredCells)).sorted()
        return .supported(
            H3Coverage(
                cells: sortedCells,
                h3Hash: hash(cells: sortedCells),
                geometryHash: try StableContentHasher.sha256Hex(of: geometry, dateEncodingStrategy: .deferredToDate),
                resolution: resolution
            )
        )
    }

    private static func cells(for rings: [[GeoShape.GeoCoordinate]]) throws -> [Int64] {
        guard let boundaryRing = rings.first, !boundaryRing.isEmpty else {
            throw SwiftyH3Error.invalidInput
        }

        let boundary: H3Loop = boundaryRing.map { coordinate in
            H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
        }
        let holes: [H3Loop] = rings.dropFirst().map { holeRing in
            holeRing.map { coordinate in
                H3LatLng(latitudeDegs: coordinate.lat, longitudeDegs: coordinate.lon)
            }
        }
        let polygon = H3Polygon(boundary, holes: holes)
        let h3Resolution = H3Cell.Resolution(rawValue: Int32(resolution)) ?? .res8
        return try polygon.cells(at: h3Resolution).map { Int64(bitPattern: $0.id) }
    }

    private static func hash(cells: [Int64]) -> String {
        var data = Data(capacity: cells.count * MemoryLayout<UInt64>.size)
        for cell in cells {
            var bigEndian = UInt64(bitPattern: cell).bigEndian
            withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        }
        return StableContentHasher.sha256Hex(of: data)
    }
}
