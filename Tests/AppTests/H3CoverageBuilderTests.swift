@testable import App
import Testing

@Suite("H3 coverage builder")
struct H3CoverageBuilderTests {
    @Test("polygon produces the characterized signed cells and hashes")
    func polygonProducesGoldenCoverage() throws {
        let coverage = try supportedCoverage(for: representativePolygon())

        #expect(coverage.cells == [
            613167731774062591,
            613167731782451199,
            613167731784548351,
            613167731843268607
        ])
        #expect(coverage.h3Hash == "1c740cb5788cb125cc0053984512bc777f494bf5a04f9385fd26bc2a578e7ba3")
        #expect(coverage.geometryHash == "fc2b6a9f7674598e3314e36295b9274074bba8a899d10edf22a1452f2ea9bd5f")
        #expect(coverage.resolution == 8)
    }

    @Test("multipolygon coverage unions duplicate cells and sorts the result")
    func multipolygonUnionsDeduplicatesAndSorts() throws {
        let geometry = GeoShape.multiPolygon(polygons: [
            representativePolygonRings(),
            representativePolygonRings(),
            adjacentPolygonRings()
        ])
        let reversedGeometry = GeoShape.multiPolygon(polygons: [
            adjacentPolygonRings(),
            representativePolygonRings(),
            representativePolygonRings()
        ])
        let coverage = try supportedCoverage(for: geometry)
        let reversedCoverage = try supportedCoverage(for: reversedGeometry)

        #expect(coverage.cells == [
            613167731774062591,
            613167731782451199,
            613167731784548351,
            613167731843268607,
            613167731857948671,
            613167731860045823,
            613167731864240127
        ])
        #expect(coverage.h3Hash == "3e28637d48fa3fe021bb17a3acd1f0fbecd7bc7a997832d114ac4bee20154d44")
        #expect(coverage.cells == coverage.cells.sorted())
        #expect(Set(coverage.cells).count == coverage.cells.count)
        #expect(reversedCoverage.cells == coverage.cells)
        #expect(reversedCoverage.h3Hash == coverage.h3Hash)
    }

    @Test("polygon holes remove cells from the outer coverage")
    func polygonHoleChangesCoverage() throws {
        let outerCoverage = try supportedCoverage(for: .polygon(rings: outerPolygonRings()))
        let holeCoverage = try supportedCoverage(for: .polygon(rings: holePolygonRings()))

        #expect(holeCoverage.cells == [
            613167729259577343,
            613167729263771647,
            613167729274257407,
            613167729276354559,
            613167729278451711,
            613167729280548863,
            613167729286840319,
            613167731667107839,
            613167731774062591,
            613167731776159743,
            613167731778256895,
            613167731780354047,
            613167731784548351,
            613167731786645503,
            613167731799228415,
            613167731803422719,
            613167731841171455,
            613167731845365759,
            613167731847462911,
            613167731849560063,
            613167731853754367,
            613167731857948671,
            613167731860045823,
            613167731864240127,
            613167731866337279
        ])
        #expect(holeCoverage.h3Hash == "5bad2af57d981c162bf4110ceffea3b471fba0dc901f9ff48e08139159c9f6d9")
        #expect(holeCoverage.geometryHash == "97125ca8538fcaffd69bffbc3ee8bfe64eb8c30c10c240910c5245c1827960ad")
        #expect(holeCoverage.cells != outerCoverage.cells)
    }

    @Test("point geometry is unsupported without attempting coverage")
    func pointIsUnsupported() throws {
        let result = try H3CoverageBuilder.build(for: .point(lon: -104.9903, lat: 39.7392))

        #expect(result == .unsupportedPoint)
    }

    @Test("invalid polygon input preserves cover failure diagnostics")
    func invalidPolygonIsCoverFailure() throws {
        let result = try H3CoverageBuilder.build(for: .polygon(rings: []))

        guard case .coverFailure(let errorDescription) = result else {
            throw H3CoverageBuilderTestError.expectedCoverFailure
        }
        #expect(errorDescription == "SwiftyH3.SwiftyH3Error.invalidInput")
    }

    @Test("repeated builds are identical")
    func repeatedBuildsAreIdentical() throws {
        let geometry = representativePolygon()

        #expect(try H3CoverageBuilder.build(for: geometry) == H3CoverageBuilder.build(for: geometry))
    }

    private func supportedCoverage(for geometry: GeoShape) throws -> H3Coverage {
        guard case .supported(let coverage) = try H3CoverageBuilder.build(for: geometry) else {
            throw H3CoverageBuilderTestError.expectedSupportedCoverage
        }
        return coverage
    }

    private func representativePolygon() -> GeoShape {
        .polygon(rings: representativePolygonRings())
    }

    private func representativePolygonRings() -> [[GeoShape.GeoCoordinate]] {
        [[
            .init(lon: -104.9903, lat: 39.7392),
            .init(lon: -104.9703, lat: 39.7392),
            .init(lon: -104.9803, lat: 39.7592),
            .init(lon: -104.9903, lat: 39.7392)
        ]]
    }

    private func adjacentPolygonRings() -> [[GeoShape.GeoCoordinate]] {
        [[
            .init(lon: -104.9703, lat: 39.7392),
            .init(lon: -104.9503, lat: 39.7392),
            .init(lon: -104.9603, lat: 39.7592),
            .init(lon: -104.9703, lat: 39.7392)
        ]]
    }

    private func outerPolygonRings() -> [[GeoShape.GeoCoordinate]] {
        [[
            .init(lon: -105.0003, lat: 39.7292),
            .init(lon: -104.9503, lat: 39.7292),
            .init(lon: -104.9503, lat: 39.7792),
            .init(lon: -105.0003, lat: 39.7792),
            .init(lon: -105.0003, lat: 39.7292)
        ]]
    }

    private func holePolygonRings() -> [[GeoShape.GeoCoordinate]] {
        outerPolygonRings() + [[
            .init(lon: -104.9853, lat: 39.7442),
            .init(lon: -104.9653, lat: 39.7442),
            .init(lon: -104.9653, lat: 39.7642),
            .init(lon: -104.9853, lat: 39.7642),
            .init(lon: -104.9853, lat: 39.7442)
        ]]
    }
}

private enum H3CoverageBuilderTestError: Error {
    case expectedCoverFailure
    case expectedSupportedCoverage
}
