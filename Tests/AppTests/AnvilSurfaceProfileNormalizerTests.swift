@testable import App
import Foundation
import Testing

@Suite("Anvil surface profile normalizer", .serialized)
struct AnvilSurfaceProfileNormalizerTests {
    @Test("complete samples normalize units and preserve fractional surface pressure")
    func completeSamplesNormalizeUnits() throws {
        let level = try AnvilSurfaceProfileNormalizer().normalize(
            samples: previewMakeSurfaceSamples(
                pressurePa: 94_040,
                heightMslM: 1_234,
                temperatureK: 295.15,
                dewpointK: 289.15,
                uWindMs: -4.25,
                vWindMs: 6.5
            )
        )

        #expect(level.pressureMb == 940.4)
        #expect(level.heightMslM == 1_234)
        #expect(level.temperatureC.isApproximatelyEqual(to: 22))
        #expect(level.dewpointC.isApproximatelyEqual(to: 16))
        #expect(level.uWindMs == -4.25)
        #expect(level.vWindMs == 6.5)
    }

    @Test("first matching value is selected deterministically")
    func firstMatchingValueIsSelected() throws {
        let samples = previewMakeSurfaceSamples(pressurePa: 94_000)
            + [previewSample("7:0:d=2026060313:PRES:surface:9 hour fcst:lon=-104.47,lat=39.79,val=95000")]

        let level = try AnvilSurfaceProfileNormalizer().normalize(samples: samples)

        #expect(level.pressureMb == 940)
    }

    @Test("missing and nonfinite fields are reported by name")
    func missingAndNonfiniteFieldsAreReported() {
        let samples = previewMakeSurfaceSamples().filter {
            !["TMP", "VGRD"].contains($0.point.inventoryDescriptor?.variable)
        }
        + [previewSample("7:0:d=2026060313:TMP:2 m above ground:9 hour fcst:lon=-104.47,lat=39.79,val=nan")]

        do {
            _ = try AnvilSurfaceProfileNormalizer().normalize(samples: samples)
            Issue.record("Expected incomplete surface profile rejection.")
        } catch let error as AnvilSurfaceProfileNormalizationError {
            #expect(error.invalidFields == [.temperature, .vWind])
            #expect(error.description.contains("TMP"))
            #expect(error.description.contains("VGRD"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("out-of-range pressure is rejected without integer conversion")
    func outOfRangePressureIsRejected() {
        do {
            _ = try AnvilSurfaceProfileNormalizer().normalize(
                samples: previewMakeSurfaceSamples(pressurePa: 9.999e20)
            )
            Issue.record("Expected invalid surface pressure rejection.")
        } catch let error as AnvilSurfaceProfileNormalizationError {
            #expect(error.invalidFields == [.pressure])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
