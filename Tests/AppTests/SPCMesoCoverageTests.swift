@testable import App
import SwiftyH3
import Testing

@Suite("SPC meso coverage")
struct SPCMesoCoverageTests {
    private func rectangle(lon: Double, lat: Double, offset: Double = 0) -> GeoShape {
        .polygon(rings: [[
            .init(lon: lon + offset - 0.00001, lat: lat - 0.00001),
            .init(lon: lon + offset + 0.00001, lat: lat - 0.00001),
            .init(lon: lon + offset + 0.00001, lat: lat + 0.00001),
            .init(lon: lon + offset - 0.00001, lat: lat + 0.00001),
            .init(lon: lon + offset - 0.00001, lat: lat - 0.00001)
        ]])
    }

    @Test func centerBasedBoundaryApproximation() throws {
        let cell = try H3LatLng(latitudeDegs: 39.7392, longitudeDegs: -104.9903).cell(at: .res8)
        let center = try cell.center
        let geometry = rectangle(lon: center.longitudeDegs, lat: center.latitudeDegs)
        let coverage = try SPCMesoCoverage.build(for: geometry)
        #expect(coverage.cells == [Int64(bitPattern: cell.id)])
        #expect(coverage.resolution == 8)
        #expect(try SPCMesoCoverage.build(for: geometry) == coverage)
        // Outside this tiny rectangle, but in the same included cell.
        let outside = H3LatLng(latitudeDegs: center.latitudeDegs, longitudeDegs: center.longitudeDegs + 0.0001)
        #expect(try outside.cell(at: .res8) == cell)
        // Move the rectangle off the cell center: its interior still maps to the
        // same cell, but the center-based cover is empty (a boundary miss).
        let shifted = try SPCMesoCoverage.build(for: rectangle(lon: center.longitudeDegs, lat: center.latitudeDegs, offset: 0.0001))
        #expect(shifted.cells.isEmpty)
        #expect(shifted.h3Hash != coverage.h3Hash)
    }

    @Test func malformedAndUnsupportedGeometryFailExplicitly() throws {
        let invalid: [GeoShape] = [
            .polygon(rings: []),
            .polygon(rings: [[.init(lon: 0, lat: 0)]]),
            .polygon(rings: [[.init(lon: 0, lat: 0), .init(lon: 1, lat: 1), .init(lon: 2, lat: 2), .init(lon: 0, lat: 0)]]),
            .polygon(rings: [[.init(lon: -90, lat: 25), .init(lon: -90.09, lat: 25.12), .init(lon: -90.03, lat: 25.04), .init(lon: -90, lat: 25)]]),
            // Crossing edges with nonzero signed area.
            .polygon(rings: [[.init(lon: 0, lat: 0), .init(lon: 2, lat: 2), .init(lon: 0, lat: 2), .init(lon: 3, lat: 0), .init(lon: 0, lat: 0)]]),
            // Nonadjacent collinear overlap.
            .polygon(rings: [[.init(lon: 0, lat: 0), .init(lon: 3, lat: 0), .init(lon: 3, lat: 3), .init(lon: 1, lat: 0), .init(lon: 2, lat: 0), .init(lon: 0, lat: 3), .init(lon: 0, lat: 0)]]),
            // Sloped centidegree edges overlap despite Double rounding residuals.
            .polygon(rings: [[.init(lon: -90, lat: 25), .init(lon: -90.09, lat: 25.12), .init(lon: -89, lat: 26), .init(lon: -90.03, lat: 25.04), .init(lon: -90.06, lat: 25.08), .init(lon: -89, lat: 24), .init(lon: -90, lat: 25)]]),
            // Repeated non-closing vertex.
            .polygon(rings: [[.init(lon: 0, lat: 0), .init(lon: 2, lat: 0), .init(lon: 1, lat: 1), .init(lon: 2, lat: 2), .init(lon: 1, lat: 1), .init(lon: 0, lat: 2), .init(lon: 0, lat: 0)]]),
            rectangle(lon: 181, lat: 40),
            rectangle(lon: 0, lat: 91)
        ]
        for geometry in invalid {
            #expect(throws: SPCMesoCoverageError.invalidPolygon) { try SPCMesoCoverage.build(for: geometry) }
        }
        #expect(throws: SPCMesoCoverageError.unsupportedGeometry) {
            try SPCMesoCoverage.build(for: .point(lon: -105, lat: 40))
        }
    }
}
