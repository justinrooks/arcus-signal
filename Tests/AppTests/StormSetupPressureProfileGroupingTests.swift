@testable import App
import Foundation
import Testing

@Suite("Storm setup pressure profile grouping", .serialized)
struct StormSetupPressureProfileGroupingTests {
    @Test("complete multi-level grouping retains descending preferred pressure levels")
    func completeMultiLevelGroupingRetainsDescendingLevels() {
        let result = group(
            samples(
                level: 1000,
                hgt: 1560,
                tmp: 295.15,
                dpt: 289.15,
                ugrd: -2.1,
                vgrd: 4.6
            )
            + [
                sample("1:0:d=2026060313:HGT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=780"),
                sample("2:0:d=2026060313:TMP:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=289.95"),
                sample("3:0:d=2026060313:DPT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=287.05"),
                sample("4:0:d=2026060313:UGRD:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-5.4"),
                sample("5:0:d=2026060313:VGRD:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=7.9")
            ]
            + samples(
                level: 850,
                hgt: 1450,
                tmp: 285.15,
                dpt: 281.15,
                ugrd: -6.25,
                vgrd: 8.75
            )
        )

        #expect(result.requestedLevels == StormSetupPressureLevel.preferredDescending)
        #expect(result.retainedLevels.map { $0.pressureMb } == [1000, 925, 850])
        #expect(result.missingLevels.contains(where: { $0.pressureMb == 975 }))
        #expect(result.retainedLevels[0].temperatureC.isApproximatelyEqual(to: 22.0))
        #expect(result.retainedLevels[0].dewpointC.isApproximatelyEqual(to: 16.0))
    }

    @Test("missing variable at one level drops that level and records the gap")
    func missingVariableDropsTheLevelWithDiagnostics() {
        let result = group(
            [
                sample("1:0:d=2026060313:HGT:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=1560"),
                sample("2:0:d=2026060313:TMP:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=295.15"),
                sample("3:0:d=2026060313:DPT:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=289.15"),
                sample("4:0:d=2026060313:UGRD:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-2.1"),
                sample("5:0:d=2026060313:VGRD:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=4.6"),
                sample("6:0:d=2026060313:HGT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=780"),
                sample("7:0:d=2026060313:TMP:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=289.95"),
                sample("8:0:d=2026060313:DPT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=287.05"),
                sample("9:0:d=2026060313:UGRD:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-5.4")
            ]
        )

        #expect(result.retainedLevels.map { $0.pressureMb } == [1000])
        let dropped925 = result.missingLevels.first(where: { $0.pressureMb == 925 })
        #expect(dropped925?.missingVariables == [StormSetupPressureProfileVariable.vgrd])
    }

    @Test("unknown variable is ignored")
    func unknownVariableIsIgnored() {
        let result = group(
            samples(
                level: 1000,
                hgt: 1560,
                tmp: 295.15,
                dpt: 289.15,
                ugrd: -2.1,
                vgrd: 4.6
            )
            + [sample("1:0:d=2026060313:WIND:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=25")]
        )

        #expect(result.retainedLevels.map { $0.pressureMb } == [1000])
        #expect(result.ignoredSamples.contains(where: { reasonMatches($0.reason, .unsupportedVariable("WIND")) }))
    }

    @Test("unsupported pressure level is ignored")
    func unsupportedPressureLevelIsIgnored() {
        let result = group(
            samples(
                level: 1000,
                hgt: 1560,
                tmp: 295.15,
                dpt: 289.15,
                ugrd: -2.1,
                vgrd: 4.6
            )
            + samples(
                level: 200,
                hgt: 1200,
                tmp: 285.15,
                dpt: 279.15,
                ugrd: -6.25,
                vgrd: 8.75
            )
        )

        #expect(result.retainedLevels.map { $0.pressureMb } == [1000])
        #expect(result.ignoredSamples.contains(where: { reasonMatches($0.reason, .unsupportedPressureLevel("200 mb")) }))
    }

    @Test("temperature and dew point convert from Kelvin to Celsius")
    func kelvinConvertsToCelsius() {
        let result = group(
            samples(
                level: 850,
                hgt: 1450,
                tmp: 285.15,
                dpt: 281.15,
                ugrd: -6.25,
                vgrd: 8.75
            )
        )

        let level = result.retainedLevels.first
        #expect(level?.temperatureC.isApproximatelyEqual(to: 12.0) == true)
        #expect(level?.dewpointC.isApproximatelyEqual(to: 8.0) == true)
    }

    @Test("duplicate records use the first usable value")
    func duplicateRecordsUseTheFirstUsableValue() {
        let result = group(
            [
                sample("1:0:d=2026060313:HGT:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=1450"),
                sample("2:0:d=2026060313:HGT:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=1490"),
                sample("3:0:d=2026060313:TMP:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=285.15"),
                sample("4:0:d=2026060313:DPT:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=281.15"),
                sample("5:0:d=2026060313:UGRD:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-6.25"),
                sample("6:0:d=2026060313:UGRD:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-1.0"),
                sample("7:0:d=2026060313:VGRD:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=8.75")
            ]
        )

        let level = result.retainedLevels.first
        #expect(level?.heightMslM == 1450)
        #expect(level?.uWindMs == -6.25)
    }

    @Test("empty and unparsable samples do not throw and retain nothing")
    func emptyOrUnparsableSamplesDoNotThrow() {
        let result = group(
            [
                sample("not even a wgrib2 inventory line"),
                sample("1:0:d=2026060313:TMP:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=missing"),
                sample("2:0:d=2026060313:TMP:bad level:9 hour fcst:lon=-104.47,lat=39.79,val=295.15")
            ]
        )

        #expect(result.retainedLevels.isEmpty)
        #expect(result.requestedLevels == StormSetupPressureLevel.preferredDescending)
        #expect(result.ignoredSamples.count == 3)
    }

    @Test("mixed valid and invalid levels still retains complete preferred levels")
    func mixedValidAndInvalidLevelsRetainCompleteLevels() {
        let result = group(
            [
                sample("1:0:d=2026060313:HGT:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=1560"),
                sample("2:0:d=2026060313:TMP:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=295.15"),
                sample("3:0:d=2026060313:DPT:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=289.15"),
                sample("4:0:d=2026060313:UGRD:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-2.1"),
                sample("5:0:d=2026060313:VGRD:1000 mb:9 hour fcst:lon=-104.47,lat=39.79,val=4.6"),
                sample("6:0:d=2026060313:HGT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=780"),
                sample("7:0:d=2026060313:TMP:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=289.95"),
                sample("8:0:d=2026060313:DPT:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=287.05"),
                sample("9:0:d=2026060313:UGRD:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-5.4"),
                sample("10:0:d=2026060313:VGRD:925 mb:9 hour fcst:lon=-104.47,lat=39.79,val=7.9"),
                sample("11:0:d=2026060313:HGT:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=1450"),
                sample("12:0:d=2026060313:TMP:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=285.15"),
                sample("13:0:d=2026060313:DPT:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=281.15"),
                sample("14:0:d=2026060313:UGRD:850 mb:9 hour fcst:lon=-104.47,lat=39.79,val=-6.25"),
                sample("15:0:d=2026060313:WIND:200 mb:9 hour fcst:lon=-104.47,lat=39.79,val=25")
            ]
        )

        #expect(result.retainedLevels.map { $0.pressureMb } == [1000, 925])
        #expect(
            result.missingLevels.contains(where: { level in
                level.pressureMb == 850 && level.missingVariables == [StormSetupPressureProfileVariable.vgrd]
            })
        )
    }

    private func group(_ samples: [HrrrFieldSample]) -> StormSetupPressureProfileGroupingResult {
        StormSetupPressureProfileGrouper().group(samples: samples)
    }

    private func samples(
        level: Int,
        hgt: Double,
        tmp: Double,
        dpt: Double,
        ugrd: Double,
        vgrd: Double
    ) -> [HrrrFieldSample] {
        [
            sample("1:0:d=2026060313:HGT:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(hgt)"),
            sample("2:0:d=2026060313:TMP:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(tmp)"),
            sample("3:0:d=2026060313:DPT:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(dpt)"),
            sample("4:0:d=2026060313:UGRD:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(ugrd)"),
            sample("5:0:d=2026060313:VGRD:\(level) mb:9 hour fcst:lon=-104.47,lat=39.79,val=\(vgrd)")
        ]
    }

    private func sample(_ line: String) -> HrrrFieldSample {
        HrrrFieldSample(
            requestedLongitude: -104.4661,
            requestedLatitude: 39.7825,
            point: Wgrib2PointSample.parse(from: line)
        )
    }

    private func reasonMatches(_ actual: StormSetupPressureProfileIgnoredSampleReason, _ expected: StormSetupPressureProfileIgnoredSampleReason) -> Bool {
        switch (actual, expected) {
        case (.missingDescriptor, .missingDescriptor),
            (.missingValue, .missingValue):
            return true
        case (.unsupportedVariable(let lhs), .unsupportedVariable(let rhs)):
            return lhs == rhs
        case (.unsupportedPressureLevel(let lhs), .unsupportedPressureLevel(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

private extension Double {
    func isApproximatelyEqual(to other: Double, tolerance: Double = 0.000_001) -> Bool {
        abs(self - other) <= tolerance
    }
}
