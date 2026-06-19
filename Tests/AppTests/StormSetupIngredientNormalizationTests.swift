@testable import App
import Foundation
import Testing

@Suite("Storm setup ingredient normalization", .serialized)
struct StormSetupIngredientNormalizationTests {
    @Test("representative CAPE inventory maps to surface-based CAPE")
    func capeInventoryMapsToSurfaceBasedCAPE() {
        let result = normalize(
            "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
        )

        #expect(result.raw.sbcapeJkg == 1450)
        #expect(result.raw.mlcapeJkg == nil)
        #expect(result.raw.mucapeJkg == nil)
        #expect(result.raw.diagnostics?.first?.matchedRawParameterKey == .sbcapeJkg)
    }

    @Test("temperature and dew point normalize from Kelvin to a Fahrenheit delta")
    func temperatureAndDewPointNormalizeToAFahrenheitDelta() {
        let result = normalize(
            [
                "1:0:d=2026060313:TMP:2 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=295.15",
                "2:0:d=2026060313:DPT:2 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=289.15"
            ]
        )

        #expect(result.raw.tempDewPtDeltaF?.isApproximatelyEqual(to: 10.8) == true)
        #expect(result.raw.temperatureDewpointSpreadF?.isApproximatelyEqual(to: 10.8) == true)
        #expect(result.raw.diagnostics?.first?.matchedRawParameterKey == .temperature2mK)
        #expect(result.raw.diagnostics?.last?.matchedRawParameterKey == .dewpoint2mK)
    }

    @Test("representative 0-3 km CAPE inventory maps to threeCape")
    func cape3InventoryMapsToThreeCape() {
        let result = normalize(
            "18:4358:d=2026061812:CAPE:0-3000 m above ground:1 hour fcst::lon=255.538301,lat=39.778672,val=0"
        )

        #expect(result.raw.threeCapeJkg == 0)
        #expect(result.raw.diagnostics?.first?.matchedRawParameterKey == .threeCapeJkg)
    }

    @Test("representative CIN inventory maps to the documented CIN field")
    func cinInventoryMapsWhenIdentifiable() {
        let result = normalize(
            "1:0:d=2026060313:CIN:90-0 mb above ground:9 hour fcst:lon=-104.47,lat=39.79,val=-35"
        )

        #expect(result.raw.mlcinJkg == -35)
        #expect(result.raw.diagnostics?.first?.matchedRawParameterKey == .mlcinJkg)
    }

    @Test("representative HLCY inventory maps to 0-1 km SRH")
    func hlcy0to1kmMapsToSrh01() {
        let result = normalize(
            "1:0:d=2026060313:HLCY:1000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=80"
        )

        #expect(result.raw.srh01kmM2s2 == 80)
        #expect(result.raw.srh03kmM2s2 == nil)
    }

    @Test("representative HLCY inventory maps to 0-3 km SRH")
    func hlcy0to3kmMapsToSrh03() {
        let result = normalize(
            "1:0:d=2026060313:HLCY:3000-0 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=160"
        )

        #expect(result.raw.srh03kmM2s2 == 160)
        #expect(result.raw.srh01kmM2s2 == nil)
    }

    @Test("0-6 km shear components map to kt with explicit conversion")
    func shearComponentsConvertToKnots() {
        let result = normalize(
            [
                "1:0:d=2026060313:VUCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=6",
                "2:0:d=2026060313:VVCSH:0-6000 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=8"
            ]
        )

        #expect(result.raw.shear06kmKt != nil)
        #expect(result.raw.shear06kmKt!.isApproximatelyEqual(to: 19.438444924406))
    }

    @Test("missing, unmatched, and non-numeric values do not throw and leave fields nil")
    func missingAndUnmatchedRecordsStayNil() {
        let result = normalize(
            [
                "1:0:d=2026060313:TMP:surface:9 hour fcst:lon=-104.47,lat=39.79,val=missing",
                "2:0:d=2026060313:WIND:surface:9 hour fcst:lon=-104.47,lat=39.79,val=25"
            ]
        )

        #expect(result.raw.sbcapeJkg == nil)
        #expect(result.raw.mlcapeJkg == nil)
        #expect(result.raw.mucapeJkg == nil)
        #expect(result.raw.mlcinJkg == nil)
        #expect(result.raw.srh01kmM2s2 == nil)
        #expect(result.raw.shear06kmKt == nil)
        #expect(result.raw.diagnostics?.count == 2)
        #expect(result.raw.diagnostics?.first?.parsedValue == nil)
    }

    @Test("duplicate candidate records resolve deterministically")
    func duplicateCandidatesUseTheFirstNumericValue() {
        let result = normalize(
            [
                "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1000",
                "2:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1200"
            ]
        )

        #expect(result.raw.sbcapeJkg == 1000)
    }

    @Test("sampler preserves requested coordinates and wraps wgrib2 samples")
    func samplerWrapsClientSamplesWithRequestedCoordinates() async throws {
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let client = StubWgrib2SamplingClient(
            response: [
                Wgrib2PointSample.parse(
                    from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"
                )
            ]
        )
        let sampler = HrrrFieldSampler(client: client)
        let subset = GribSubsetCacheResult(
            source: makeSourceMetadata(),
            localFileURL: URL(fileURLWithPath: "/tmp/sample.grib2"),
            byteSize: 123,
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            expiresAt: makeUTCDate(year: 2026, month: 6, day: 4, hour: 22),
            cacheHit: true
        )

        let samples = try await sampler.sample(from: subset, around: centroid)

        #expect(samples.count == 1)
        #expect(samples[0].requestedLatitude == centroid.latitude)
        #expect(samples[0].requestedLongitude == centroid.longitude)
        #expect(samples[0].point.value == 1450)
    }

    private func normalize(_ line: String) -> TornadoIngredientNormalizationResult {
        normalize([line])
    }

    private func normalize(_ lines: [String]) -> TornadoIngredientNormalizationResult {
        let samples = lines.map { line in
            HrrrFieldSample(
                requestedLongitude: -104.4661,
                requestedLatitude: 39.7825,
                point: Wgrib2PointSample.parse(from: line)
            )
        }

        return TornadoIngredientNormalizer().normalize(samples: samples)
    }

    private func makeSourceMetadata() -> StormSetupSourceMetadata {
        let candidate = HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        return HrrrNomadsURLBuilder().makeSourceMetadata(
            for: candidate,
            around: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        )
    }
}

private struct StubWgrib2SamplingClient: Wgrib2Sampling {
    let response: [Wgrib2PointSample]

    func samplePoint(_ request: Wgrib2PointRequest) async throws -> [Wgrib2PointSample] {
        _ = request
        return response
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}

private func makeUTCDate(
    year: Int,
    month: Int,
    day: Int,
    hour: Int,
    minute: Int = 0,
    second: Int = 0
) -> Date {
    let components = DateComponents(
        timeZone: TimeZone(secondsFromGMT: 0),
        year: year,
        month: month,
        day: day,
        hour: hour,
        minute: minute,
        second: second
    )

    guard let date = StormSetupUTC.calendar.date(from: components) else {
        preconditionFailure("Unable to create UTC date for test.")
    }

    return date
}
