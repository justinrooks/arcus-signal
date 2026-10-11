import Foundation

enum SPCMesoCoverageError: Error, Equatable {
    case invalidPolygon
    case unsupportedGeometry
    case generationFailed(String)
}

/// Meso coverage uses the canonical center-based res-8 polyfill, without ring expansion.
enum SPCMesoCoverage {
    static func build(for geometry: GeoShape) throws -> H3Coverage {
        guard case .polygon(let rings) = geometry else {
            throw SPCMesoCoverageError.unsupportedGeometry
        }
        guard rings.count == 1, let ring = rings.first, ring.count >= 4,
              ring.first == ring.last,
              ring.allSatisfy({ $0.lat.isFinite && $0.lon.isFinite &&
                  (-90...90).contains($0.lat) && (-180...180).contains($0.lon) }) else {
            throw SPCMesoCoverageError.invalidPolygon
        }
        // A simple closed ring needs at least one noncollinear vertex.
        guard ring.dropFirst(2).contains(where: { orientation(ring[0], ring[1], $0) != 0 }) else {
            throw SPCMesoCoverageError.invalidPolygon
        }
        let edges = Array(zip(ring, ring.dropFirst()))
        for i in edges.indices {
            guard edges[i].0 != edges[i].1 else { throw SPCMesoCoverageError.invalidPolygon }
            for j in edges.indices where j > i + 1 && !(i == 0 && j == edges.count - 1) {
                if intersects(edges[i], edges[j]) { throw SPCMesoCoverageError.invalidPolygon }
            }
        }
        switch try H3CoverageBuilder.build(for: geometry) {
        case .supported(let coverage): return coverage
        case .unsupportedPoint: throw SPCMesoCoverageError.unsupportedGeometry
        case .coverFailure(let description): throw SPCMesoCoverageError.generationFailed(description)
        }
    }

    private static func orientation(_ a: GeoShape.GeoCoordinate, _ b: GeoShape.GeoCoordinate, _ c: GeoShape.GeoCoordinate) -> Int {
        let dx = b.lon - a.lon, dy = b.lat - a.lat
        let ex = c.lon - a.lon, ey = c.lat - a.lat
        let determinant = dx * ey - dy * ex
        // Account for rounding in coordinate subtraction as well as products.
        // Scaling by edge length keeps small valid polygons distinguishable.
        let coordinateScale = abs(a.lon) + abs(a.lat) + abs(b.lon) + abs(b.lat) + abs(c.lon) + abs(c.lat)
        let edgeScale = max(max(abs(dx), abs(dy)), max(abs(ex), abs(ey)))
        let tolerance = 8 * Double.ulpOfOne * coordinateScale * edgeScale
        if abs(determinant) <= tolerance { return 0 }
        return determinant < 0 ? -1 : 1
    }

    private static func intersects(
        _ lhs: (GeoShape.GeoCoordinate, GeoShape.GeoCoordinate),
        _ rhs: (GeoShape.GeoCoordinate, GeoShape.GeoCoordinate)
    ) -> Bool {
        func contains(_ p: GeoShape.GeoCoordinate, on edge: (GeoShape.GeoCoordinate, GeoShape.GeoCoordinate)) -> Bool {
            p.lon >= min(edge.0.lon, edge.1.lon) && p.lon <= max(edge.0.lon, edge.1.lon) &&
            p.lat >= min(edge.0.lat, edge.1.lat) && p.lat <= max(edge.0.lat, edge.1.lat)
        }
        let a = orientation(lhs.0, lhs.1, rhs.0)
        let b = orientation(lhs.0, lhs.1, rhs.1)
        let c = orientation(rhs.0, rhs.1, lhs.0)
        let d = orientation(rhs.0, rhs.1, lhs.1)
        return (a * b < 0 && c * d < 0) ||
            (a == 0 && contains(rhs.0, on: lhs)) || (b == 0 && contains(rhs.1, on: lhs)) ||
            (c == 0 && contains(lhs.0, on: rhs)) || (d == 0 && contains(lhs.1, on: rhs))
    }
}
