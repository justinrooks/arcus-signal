@testable import App
import Foundation
import Testing

@Suite("Storm setup ingredient assessment", .serialized)
struct TornadoIngredientInterpreterTests {
    @Test("weak setup yields overall weak")
    func weakSetupYieldsWeakOverall() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 250,
                mlcapeJkg: 300,
                mucapeJkg: 400,
                mlcinJkg: -140,
                mllclM: 1500,
                temperatureDewpointSpreadF: 24,
                shear06kmKt: 20,
                srh01kmM2s2: 40,
                srh03kmM2s2: 55
            )
        )

        #expect(assessment.overall == .weak)
    }

    @Test("conditional setup yields overall conditional")
    func conditionalSetupYieldsConditionalOverall() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1200,
                mlcapeJkg: 1300,
                mucapeJkg: 1500,
                mlcinJkg: -40,
                mllclM: 950,
                temperatureDewpointSpreadF: 17,
                shear06kmKt: 42,
                srh01kmM2s2: 90,
                srh03kmM2s2: 140
            )
        )

        #expect(assessment.overall == .conditional)
    }

    @Test("supportive setup yields overall supportive")
    func supportiveSetupYieldsSupportiveOverall() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1400,
                mlcapeJkg: 1600,
                mucapeJkg: 1700,
                mlcinJkg: -35,
                mllclM: 850,
                temperatureDewpointSpreadF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 120,
                srh03kmM2s2: 190
            )
        )

        #expect(assessment.overall == .supportive)
    }

    @Test("strong setup yields overall strong only when multiple pillars strongly agree")
    func strongSetupRequiresMultipleStrongPillars() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2600,
                mlcapeJkg: 2800,
                mucapeJkg: 3000,
                mlcinJkg: -15,
                mllclM: 700,
                temperatureDewpointSpreadF: 6,
                shear06kmKt: 58,
                srh01kmM2s2: 260,
                srh03kmM2s2: 320,
                supercellComposite: 4.5,
                significantTornadoFixed: 3.1,
                significantTornadoEffective: 4.2
            )
        )

        #expect(assessment.overall == .strong)
        #expect(assessment.confidence == .high)
    }

    @Test("missing core fields yields unknown and degraded confidence")
    func missingCoreFieldsYieldUnknownAndDegradedConfidence() {
        let assessment = interpret(raw: .empty)

        #expect(assessment.overall == .unknown)
        #expect(assessment.confidence == .degraded)
        #expect(assessment.summary.contains("not enough ingredient data"))
    }

    @Test("weak low-level rotation is a limiting factor when instability and deep shear are present")
    func weakLowLevelRotationIsLimitingFactor() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1500,
                mlcapeJkg: 1600,
                mucapeJkg: 1700,
                mlcinJkg: -35,
                mllclM: 900,
                temperatureDewpointSpreadF: 12,
                shear06kmKt: 45,
                srh01kmM2s2: 45,
                srh03kmM2s2: 60
            )
        )

        #expect(assessment.overall == .conditional)
        #expect(assessment.limitingFactors.contains(.weakLowLevelRotation))
    }

    @Test("elevated cloud bases appear as a limiting factor when MLLCL is high")
    func elevatedCloudBasesAreLimitingFactor() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1500,
                mlcapeJkg: 1600,
                mucapeJkg: 1700,
                mlcinJkg: -20,
                mllclM: 1450,
                temperatureDewpointSpreadF: 24,
                shear06kmKt: 45,
                srh01kmM2s2: 100,
                srh03kmM2s2: 180
            )
        )

        #expect(assessment.limitingFactors.contains(.elevatedCloudBases))
    }

    @Test("stale source metadata produces degraded freshness and confidence")
    func staleSourceMetadataProducesDegradedFreshnessAndConfidence() {
        let fetchedAt = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let source = StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19),
            forecastHour: 3,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoV1,
            bbox: nil,
            nomadsURL: nil
        )

        let freshness = IngredientFreshness.make(source: source, fetchedAt: fetchedAt, staleAfter: 30 * 60)
        let assessment = TornadoIngredientInterpreter().assess(
            raw: makeRaw(
                sbcapeJkg: 1500,
                mlcapeJkg: 1600,
                mucapeJkg: 1700,
                mlcinJkg: -20,
                mllclM: 900,
                temperatureDewpointSpreadF: 12,
                shear06kmKt: 45,
                srh01kmM2s2: 100,
                srh03kmM2s2: 180
            ),
            freshness: freshness
        )

        #expect(freshness.isStale)
        #expect(freshness.isDegraded)
        #expect(assessment.confidence == .degraded)
    }

    @Test("summaries avoid prohibited prediction language")
    func summariesAvoidProhibitedPredictionLanguage() {
        let summary = interpret(
            raw: makeRaw(
                sbcapeJkg: 1200,
                mlcapeJkg: 1300,
                mucapeJkg: 1500,
                mlcinJkg: -40,
                mllclM: 950,
                temperatureDewpointSpreadF: 17,
                shear06kmKt: 42,
                srh01kmM2s2: 90,
                srh03kmM2s2: 140
            )
        ).summary.lowercased()

        #expect(!summary.contains("likely"))
        #expect(!summary.contains("probability"))
        #expect(!summary.contains("predictor"))
        #expect(!summary.contains("risk score"))
        #expect(!summary.contains("at your exact location"))
    }

    private func interpret(raw: TornadoRawParameters) -> TornadoIngredientAssessment {
        let source = StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: .tornadoV1,
            bbox: nil,
            nomadsURL: nil
        )
        let freshness = IngredientFreshness.make(
            source: source,
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        )
        return TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness)
    }

    private func makeRaw(
        sbcapeJkg: Double? = nil,
        mlcapeJkg: Double? = nil,
        mucapeJkg: Double? = nil,
        mlcinJkg: Double? = nil,
        mllclM: Double? = nil,
        temperatureDewpointSpreadF: Double? = nil,
        shear06kmKt: Double? = nil,
        effectiveShearKt: Double? = nil,
        srh01kmM2s2: Double? = nil,
        srh03kmM2s2: Double? = nil,
        effectiveSrhM2s2: Double? = nil,
        supercellComposite: Double? = nil,
        significantTornadoFixed: Double? = nil,
        significantTornadoEffective: Double? = nil
    ) -> TornadoRawParameters {
        TornadoRawParameters(
            sbcapeJkg: sbcapeJkg,
            mlcapeJkg: mlcapeJkg,
            mucapeJkg: mucapeJkg,
            mlcinJkg: mlcinJkg,
            dcapeJkg: nil,
            mllclM: mllclM,
            temperatureDewpointSpreadF: temperatureDewpointSpreadF,
            lclLfcSeparationM: nil,
            lapseRate03kmCkm: nil,
            lapseRate700500mbCkm: nil,
            shear06kmKt: shear06kmKt,
            shear03kmKt: nil,
            shear01kmKt: nil,
            effectiveShearKt: effectiveShearKt,
            srh01kmM2s2: srh01kmM2s2,
            srh03kmM2s2: srh03kmM2s2,
            effectiveSrhM2s2: effectiveSrhM2s2,
            supercellComposite: supercellComposite,
            significantTornadoFixed: significantTornadoFixed,
            significantTornadoEffective: significantTornadoEffective,
            significantHail: nil,
            bunkersRightMotion: nil,
            bunkersLeftMotion: nil,
            stormRelativeWind46km: nil,
            meanWind850300mb: nil,
            diagnostics: nil
        )
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
