@testable import App
import Foundation
import Testing

@Suite("Storm setup HRRR source selection", .serialized)
struct StormSetupHrrrSourceTests {
    @Test("fixed clock produces ordered HRRR candidates and valid times")
    func resolverProducesOrderedCandidates() throws {
        let fixedNow = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let resolver = DefaultHrrrRunResolver(
            dateProvider: FixedStormSetupDateProvider(nowDate: fixedNow),
            lookbackHours: 9
        )

        let resolution = resolver.resolveRunCandidates()

        #expect(resolution.targetValidTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
        #expect(resolution.candidates.count == 10)
        #expect(resolution.candidates.prefix(3).map(\.fileName) == [
            "hrrr.t22z.wrfsfcf00.grib2",
            "hrrr.t21z.wrfsfcf01.grib2",
            "hrrr.t20z.wrfsfcf02.grib2"
        ])

        let candidate = resolution.candidates[9]
        let expectedValidTime = StormSetupUTC.calendar.date(byAdding: .hour, value: candidate.forecastHour, to: candidate.runTime)

        #expect(candidate.fileName == "hrrr.t13z.wrfsfcf09.grib2")
        #expect(candidate.runTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 13))
        #expect(candidate.validTime == expectedValidTime)
        #expect(candidate.validTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
    }

    @Test("resolver omits candidates outside the configured lookback window")
    func resolverRejectsTooOldCandidates() throws {
        let fixedNow = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let resolver = DefaultHrrrRunResolver(
            dateProvider: FixedStormSetupDateProvider(nowDate: fixedNow),
            lookbackHours: 2
        )

        let resolution = resolver.resolveRunCandidates()

        #expect(resolution.candidates.count == 3)
        #expect(resolution.candidates.map(\.fileName) == [
            "hrrr.t22z.wrfsfcf00.grib2",
            "hrrr.t21z.wrfsfcf01.grib2",
            "hrrr.t20z.wrfsfcf02.grib2"
        ])
    }

    @Test("NOMADS URL builder includes the tornado-v1 fields, levels, and bbox")
    func urlBuilderIncludesTornadoFieldSet() throws {
        let candidate = HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let builder = HrrrNomadsURLBuilder()

        let metadata = builder.makeSourceMetadata(for: candidate, around: centroid)
        let urlString = metadata.nomadsURL?.absoluteString ?? ""

        #expect(metadata.model == .hrrr)
        #expect(metadata.product == .wrfsfc)
        #expect(metadata.domain == .conus)
        #expect(metadata.runTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 13))
        #expect(metadata.forecastHour == 9)
        #expect(metadata.validTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
        #expect(metadata.fieldSetVersion == .tornadoV1)
        #expect(metadata.bbox == StormSetupHrrrBoundingBox(around: centroid))
        #expect(urlString.contains("dir=%2Fhrrr.20260603%2Fconus"))
        #expect(urlString.contains("file=hrrr.t13z.wrfsfcf09.grib2"))
        #expect(urlString.contains("var_CAPE=on"))
        #expect(urlString.contains("var_CIN=on"))
        #expect(urlString.contains("var_HLCY=on"))
        #expect(urlString.contains("var_VUCSH=on"))
        #expect(urlString.contains("var_VVCSH=on"))
        #expect(urlString.contains("var_USTM=on"))
        #expect(urlString.contains("var_VSTM=on"))
        #expect(urlString.contains("var_HGT=on"))
        #expect(urlString.contains("lev_surface=on"))
        #expect(urlString.contains("lev_90-0_mb_above_ground=on"))
        #expect(urlString.contains("lev_255-0_mb_above_ground=on"))
        #expect(urlString.contains("lev_1000-0_m_above_ground=on"))
        #expect(urlString.contains("lev_3000-0_m_above_ground=on"))
        #expect(urlString.contains("lev_0-6000_m_above_ground=on"))
        #expect(urlString.contains("lev_level_of_adiabatic_condensation_from_sfc=on"))
        #expect(urlString.contains("leftlon=-104.62"))
        #expect(urlString.contains("rightlon=-104.32"))
        #expect(urlString.contains("toplat=39.96"))
        #expect(urlString.contains("bottomlat=39.61"))
        #expect(!urlString.contains("latest"))
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
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
