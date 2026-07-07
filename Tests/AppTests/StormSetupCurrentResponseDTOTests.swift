@testable import App
import Foundation
import Testing

@Suite("Storm setup current response DTOs", .serialized)
struct StormSetupCurrentResponseDTOTests {
    @Test("response DTO encodes the explicit sections")
    func responseEncodesExplicitSections() throws {
        let response = makeResponse(profileAnalysis: makeProfileAnalysis())
        let encoded = try encoder().encode(response)

        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?.keys.sorted() == ["assessment", "ingredients", "profileAnalysis", "setup"])

        let setupObject = object?["setup"] as? [String: Any]
        #expect(setupObject?.keys.sorted() == ["centroid", "freshness", "h3Cell", "source", "surfaceHeightMslM"])

        let decoded = try decoder().decode(StormSetupCurrentResponse.self, from: encoded)
        #expect(decoded.setup.h3Cell == response.setup.h3Cell)
        #expect(decoded.setup.centroid == response.setup.centroid)
        #expect(decoded.setup.source == response.setup.source)
        #expect(decoded.setup.surfaceHeightMslM == response.setup.surfaceHeightMslM)
        #expect(decoded.setup.freshness.sourceValidTime == response.setup.freshness.sourceValidTime)
        #expect(decoded.setup.freshness.modelRunTime == response.setup.freshness.modelRunTime)
        #expect(decoded.setup.freshness.forecastHour == response.setup.freshness.forecastHour)
        #expect(decoded.setup.freshness.fetchedAt == response.setup.freshness.fetchedAt)
        #expect(decoded.setup.freshness.expiresAt == response.setup.freshness.expiresAt)
        #expect(decoded.setup.freshness.isStale == response.setup.freshness.isStale)
        #expect(decoded.setup.freshness.isDegraded == response.setup.freshness.isDegraded)
        #expect(decoded.ingredients.sbcapeJkg == response.ingredients.sbcapeJkg)
        #expect(decoded.profileAnalysis == response.profileAnalysis)
        #expect(decoded.assessment.overall == response.assessment.overall)
        #expect(decoded.assessment.confidence == response.assessment.confidence)
        #expect(decoded.assessment.summary == response.assessment.summary)
        #expect(decoded.assessment.primaryDrivers == response.assessment.primaryDrivers)
        #expect(decoded.assessment.limitingFactors == response.assessment.limitingFactors)
    }

    @Test("response DTO allows a missing profile analysis")
    func responseAllowsMissingProfileAnalysis() throws {
        let response = makeResponse(profileAnalysis: nil)
        let decoded = try roundTrip(response)

        #expect(decoded.profileAnalysis == nil)
        #expect(decoded.setup.h3Cell == response.setup.h3Cell)
        #expect(decoded.assessment.summary == response.assessment.summary)
    }

    private func makeResponse(profileAnalysis: AnvilAnalyzeProfileResponse?) -> StormSetupCurrentResponse {
        StormSetupCurrentResponse(
            setup: StormSetupCurrentSetupResponse(
                h3Cell: 617_700_169_958_293_503,
                centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
                source: StormSetupSourceMetadata(
                    model: .hrrr,
                    product: .wrfsfc,
                    domain: .conus,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    forecastHour: 0,
                    validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    fieldSetVersion: .tornadoV1,
                    bbox: nil,
                    nomadsURL: URL(string: "https://example.com/filter_hrrr_2d.pl")
                ),
                surfaceHeightMslM: 432.1,
                freshness: IngredientFreshness(
                    sourceValidTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    modelRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    forecastHour: 0,
                    fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45),
                    expiresAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 30),
                    isStale: false,
                    isDegraded: false
                )
            ),
            ingredients: TornadoRawParameters(
                sbcapeJkg: 1450,
                mlcapeJkg: 980,
                mucapeJkg: 1710,
                mlcinJkg: -35,
                dcapeJkg: nil,
                mllclM: 1150,
                lclLfcSeparationM: 210,
                lapseRate03kmCkm: nil,
                lapseRate700500mbCkm: nil,
                shear06kmKt: 31,
                shear03kmKt: 25,
                shear01kmKt: 18,
                effectiveShearKt: 34,
                srh01kmM2s2: 120,
                srh03kmM2s2: 180,
                effectiveSrhM2s2: 145,
                supercellComposite: 2.4,
                significantTornadoFixed: 1.7,
                significantTornadoEffective: 2.1,
                significantHail: 0.8,
                bunkersRightMotion: nil,
                bunkersLeftMotion: nil,
                stormRelativeWind46km: nil,
                meanWind850300mb: nil,
                diagnostics: nil
            ),
            profileAnalysis: profileAnalysis,
            assessment: makeAssessment()
        )
    }

    private func makeAssessment() -> TornadoIngredientAssessment {
        TornadoIngredientAssessment(
            overall: .conditional,
            instability: .supportive,
            moisture: .strong,
            cloudBase: .conditional,
            capInhibition: .weak,
            deepShear: .supportive,
            lowLevelRotation: .supportive,
            stormMode: .conditional,
            compositeSignal: .supportive,
            confidence: .moderate,
            trend: .steady,
            stormModeHint: .mixedMode,
            primaryDrivers: ["Instability is adequate.", "Shear remains organized."],
            limitingFactors: [.weakLift],
            summary: "Conditions remain conditionally supportive."
        )
    }

    private func makeProfileAnalysis() -> AnvilAnalyzeProfileResponse {
        AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: "found",
                basePressureMb: 1000,
                topPressureMb: 925,
                baseMetersAgl: 0,
                topMetersAgl: 690
            ),
            stormMotion: AnvilStormMotionDTO(
                status: "computed",
                bunkersRight: AnvilBunkersRightStormMotionDTO(
                    uKt: 36.8,
                    vKt: 13.5,
                    speedKt: 39.2,
                    directionTowardDeg: 69.8,
                    uMs: 18.9,
                    vMs: 7.0,
                    speedMs: 20.2
                )
            ),
            mucape: 362.1,
            mlcape: 191.7,
            mlcin: -221.9,
            mllclMetersAgl: 1179.4,
            effectiveSrh: 29.4,
            effectiveBulkShearMs: 30.1,
            scp: 0.21,
            stpCin: 0.0,
            stpFixed: 0.10,
            ship: 0.02,
            quality: AnvilQualityDTO(
                profileLevelCount: 20,
                warnings: []
            )
        )
    }

    private func roundTrip<T: Codable & Sendable>(_ value: T) throws -> T {
        let data = try encoder().encode(value)
        return try decoder().decode(T.self, from: data)
    }

    private func encoder() -> JSONEncoder {
        JSONEncoder()
    }

    private func decoder() -> JSONDecoder {
        JSONDecoder()
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

        guard let date = Calendar(identifier: .gregorian).date(from: components) else {
            preconditionFailure("Unable to create UTC date for test.")
        }

        return date
    }
}
