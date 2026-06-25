@testable import App
import Foundation
import Testing

@Suite("Storm setup HRRR source selection", .serialized)
struct StormSetupHrrrSourceTests {
    @Test("HRRR products generate the expected file names")
    func productFileNamesAreCorrect() throws {
        #expect(HrrrProduct.wrfsfc.fileNameStem == "wrfsfcf")
        #expect(HrrrProduct.wrfprsf.fileNameStem == "wrfprsf")

        let surfaceCandidate = HrrrRunCandidate(
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9
        )
        let pressureCandidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            fieldSetVersion: .tornadoPressureV1
        )

        #expect(surfaceCandidate.fileName == "hrrr.t13z.wrfsfcf09.grib2")
        #expect(pressureCandidate.fileName == "hrrr.t13z.wrfprsf09.grib2")
    }

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
        let urlString = metadata.primaryDownloadURL?.absoluteString ?? ""

        #expect(metadata.sourceKind == .nomadsFilteredSubset)
        #expect(metadata.model == .hrrr)
        #expect(metadata.product == .wrfsfc)
        #expect(metadata.domain == .conus)
        #expect(metadata.runTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 13))
        #expect(metadata.forecastHour == 9)
        #expect(metadata.validTime == makeUTCDate(year: 2026, month: 6, day: 3, hour: 22))
        #expect(metadata.fieldSetVersion == .tornadoV1)
        #expect(metadata.bbox == StormSetupHrrrBoundingBox(around: centroid))
        #expect(urlString.contains("dir=%2Fhrrr.20260603%2Fconus"))
        #expect(urlString.contains("/cgi-bin/filter_hrrr_2d.pl"))
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

    @Test("NOMADS URL builder includes pressure-level variables and levels")
    func urlBuilderIncludesPressureFieldSet() throws {
        let candidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            fieldSetVersion: .tornadoPressureV1
        )
        let centroid = StormSetupCentroid(latitude: 39.7825, longitude: -104.4661)
        let builder = HrrrNomadsURLBuilder()

        let metadata = builder.makeSourceMetadata(for: candidate, around: centroid)
        let urlString = metadata.primaryDownloadURL?.absoluteString ?? ""

        #expect(metadata.sourceKind == .nomadsFilteredSubset)
        #expect(metadata.model == .hrrr)
        #expect(metadata.product == .wrfprsf)
        #expect(metadata.primaryDownloadURL != nil)
        #expect(metadata.idxURL == nil)
        #expect(metadata.fieldSetVersion == .tornadoPressureV1)
        #expect(urlString.contains("/cgi-bin/filter_hrrr.pl"))
        #expect(urlString.contains("file=hrrr.t13z.wrfprsf09.grib2"))
        #expect(urlString.contains("var_HGT=on"))
        #expect(urlString.contains("var_TMP=on"))
        #expect(urlString.contains("var_DPT=on"))
        #expect(urlString.contains("var_UGRD=on"))
        #expect(urlString.contains("var_VGRD=on"))
        #expect(urlString.contains("lev_850_mb=on"))
        #expect(urlString.contains("lev_700_mb=on"))
        #expect(urlString.contains("lev_500_mb=on"))
        #expect(urlString.contains("lev_300_mb=on"))
        #expect(!urlString.contains("var_CAPE=on"))
        #expect(!urlString.contains("lev_surface=on"))
    }

    @Test("source metadata can represent a direct pressure object without a NOMADS filter")
    func sourceMetadataCanRepresentDirectObjectSources() throws {
        let directURL = URL(string: "https://example.com/hrrr/wrfprsf/hrrr.t13z.wrfprsf09.grib2")!
        let metadata = StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: .hrrr,
            product: .wrfprsf,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoPressureV1,
            primaryDownloadURL: directURL,
            idxURL: nil
        )

        #expect(metadata.sourceKind == .directObject)
        #expect(metadata.primaryDownloadURL == directURL)
        #expect(metadata.nomadsURL == directURL)
        #expect(metadata.idxURL == nil)
        #expect(metadata.bbox == nil)
    }

    @Test("pressure candidates preserve valid time and direct-object file naming")
    func pressureCandidatesPreserveTimingAndFileNames() throws {
        let runTime = makeUTCDate(year: 2026, month: 6, day: 19, hour: 21)

        let forecastZero = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: 0,
            fieldSetVersion: .tornadoPressureV1
        )
        let forecastNine = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: 9,
            fieldSetVersion: .tornadoPressureV1
        )
        let forecastTwelve = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: 12,
            fieldSetVersion: .tornadoPressureV1
        )

        #expect(forecastZero.fileName == "hrrr.t21z.wrfprsf00.grib2")
        #expect(forecastNine.fileName == "hrrr.t21z.wrfprsf09.grib2")
        #expect(forecastTwelve.fileName == "hrrr.t21z.wrfprsf12.grib2")
        #expect(forecastTwelve.validTime == makeUTCDate(year: 2026, month: 6, day: 20, hour: 9))
    }

    @Test("pressure direct-object URLs resolve from the NOAA AWS bucket using the prior hour cycle")
    func pressureDirectObjectUrlsResolveFromAWS() async throws {
        let candidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0,
            fieldSetVersion: .tornadoPressureV1
        )
        let builder = HrrrPressureDirectObjectURLBuilder()
        let resolver = DefaultHrrrPressureDirectObjectResolver(checker: StubHrrrRemoteObjectChecking(
            availableURLs: [
                builder.makeIdxURL(for: HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
                    forecastHour: 1,
                    fieldSetVersion: .tornadoPressureV1
                )).absoluteString: true
            ]
        ), urlBuilder: builder)

        let metadata = try await resolver.resolveSource(
            for: HrrrRunResolution(
                targetValidTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
                candidates: [candidate]
            )
        ).source

        #expect(metadata.sourceKind == .directObject)
        #expect(metadata.model == .hrrr)
        #expect(metadata.product == .wrfprsf)
        #expect(metadata.domain == .conus)
        #expect(metadata.runTime == makeUTCDate(year: 2026, month: 6, day: 19, hour: 20))
        #expect(metadata.forecastHour == 1)
        #expect(metadata.validTime == makeUTCDate(year: 2026, month: 6, day: 19, hour: 21))
        #expect(metadata.fieldSetVersion == .tornadoPressureV1)
        #expect(metadata.bbox == nil)
        #expect(metadata.primaryDownloadURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260619/conus/hrrr.t20z.wrfprsf01.grib2")
        #expect(metadata.idxURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260619/conus/hrrr.t20z.wrfprsf01.grib2.idx")
    }

    @Test("pressure direct-object resolver prefers the newest available candidate")
    func pressureDirectObjectResolverPrefersNewestAvailableCandidate() async throws {
        let newer = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0,
            fieldSetVersion: .tornadoPressureV1
        )
        let older = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
            forecastHour: 1,
            fieldSetVersion: .tornadoPressureV1
        )
        let resolution = HrrrRunResolution(
            targetValidTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            candidates: [newer, older]
        )
        let checker = StubHrrrRemoteObjectChecking(
            availableURLs: [
                HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
                    forecastHour: 1,
                    fieldSetVersion: .tornadoPressureV1
                )).absoluteString: true
            ]
        )
        let resolver = DefaultHrrrPressureDirectObjectResolver(checker: checker)

        let result = try await resolver.resolveSource(for: resolution)

        #expect(result.candidate == HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
            forecastHour: 1,
            fieldSetVersion: .tornadoPressureV1
        ))
        #expect(result.source.sourceKind == HrrrSourceKind.directObject)
        #expect(result.source.primaryDownloadURL?.absoluteString == "https://noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.20260619/conus/hrrr.t20z.wrfprsf01.grib2")
        #expect(result.idxProbe.available == true)
        #expect(result.gribProbe == nil)
        #expect(checker.requestedURLs == [
            HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
                forecastHour: 1,
                fieldSetVersion: .tornadoPressureV1
            )).absoluteString
        ])
    }

    @Test("pressure direct-object resolver skips GRIB-only candidates and keeps walking backward")
    func pressureDirectObjectResolverSkipsGribOnlyCandidates() async throws {
        let newest = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            forecastHour: 0,
            fieldSetVersion: .tornadoPressureV1
        )
        let middle = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
            forecastHour: 1,
            fieldSetVersion: .tornadoPressureV1
        )
        let oldest = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 19),
            forecastHour: 2,
            fieldSetVersion: .tornadoPressureV1
        )
        let builder = HrrrPressureDirectObjectURLBuilder()
        let checker = StubHrrrRemoteObjectChecking(
            availableURLs: [
                builder.makeIdxURL(for: HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 19),
                    forecastHour: 2,
                    fieldSetVersion: .tornadoPressureV1
                )).absoluteString: true,
                builder.makeIdxURL(for: HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 18),
                    forecastHour: 3,
                    fieldSetVersion: .tornadoPressureV1
                )).absoluteString: false,
                builder.makeGribURL(for: HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 18),
                    forecastHour: 3,
                    fieldSetVersion: .tornadoPressureV1
                )).absoluteString: true
            ]
        )
        let resolver = DefaultHrrrPressureDirectObjectResolver(checker: checker, urlBuilder: builder)
        let resolution = HrrrRunResolution(
            targetValidTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            candidates: [newest, middle, oldest]
        )

        let result = try await resolver.resolveSource(for: resolution)

        #expect(result.candidate == HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 19),
            forecastHour: 2,
            fieldSetVersion: .tornadoPressureV1
        ))
        #expect(result.idxProbe.available == true)
        #expect(result.gribProbe == nil)
        #expect(checker.requestedURLs == [
            builder.makeIdxURL(for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
                forecastHour: 1,
                fieldSetVersion: .tornadoPressureV1
            )).absoluteString,
            builder.makeGribURL(for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
                forecastHour: 1,
                fieldSetVersion: .tornadoPressureV1
            )).absoluteString,
            builder.makeIdxURL(for: HrrrRunCandidate(
                product: .wrfprsf,
                runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 19),
                forecastHour: 2,
                fieldSetVersion: .tornadoPressureV1
            )).absoluteString
        ])
    }

    @Test("pressure direct-object resolver reports a clear failure when IDX is missing even if GRIB exists")
    func pressureDirectObjectResolverFailsClearlyWhenIDXIsMissingEvenIfGRIBExists() async throws {
        let candidate = HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 20),
            forecastHour: 1,
            fieldSetVersion: .tornadoPressureV1
        )
        let builder = HrrrPressureDirectObjectURLBuilder()
        let checker = StubHrrrRemoteObjectChecking(
            availableURLs: [
                builder.makeIdxURL(for: candidate).absoluteString: false,
                builder.makeGribURL(for: candidate).absoluteString: true
            ]
        )
        let resolver = DefaultHrrrPressureDirectObjectResolver(checker: checker, urlBuilder: builder)
        let resolution = HrrrRunResolution(
            targetValidTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
            candidates: [
                HrrrRunCandidate(
                    product: .wrfprsf,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 19, hour: 21),
                    forecastHour: 0,
                    fieldSetVersion: .tornadoPressureV1
                )
            ]
        )

        do {
            _ = try await resolver.resolveSource(for: resolution)
            Issue.record("Expected the pressure resolver to fail when no source is available.")
        } catch let error as HrrrPressureDirectObjectResolverError {
            if case .noAvailableCandidate = error {
                #expect(error.description.contains("No usable HRRR pressure direct-object candidate"))
                #expect(error.description.contains("IDX unavailable"))
                #expect(error.description.contains("GRIB available"))
                #expect(checker.requestedURLs == [
                    builder.makeIdxURL(for: candidate).absoluteString,
                    builder.makeGribURL(for: candidate).absoluteString
                ])
                return
            }
            Issue.record("Expected a no-available-candidate error but got \(error).")
        }
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

final class StubHrrrRemoteObjectChecking: HrrrRemoteObjectChecking, @unchecked Sendable {
    let availableURLs: [String: Bool]
    private(set) var requestedURLs: [String] = []

    init(availableURLs: [String: Bool] = [:]) {
        self.availableURLs = availableURLs
    }

    func probe(url: URL) async -> HrrrRemoteObjectProbeResult {
        requestedURLs.append(url.absoluteString)
        let available = availableURLs[url.absoluteString] ?? false
        return HrrrRemoteObjectProbeResult(
            url: url,
            available: available,
            status: available ? 200 : 404
        )
    }
}
