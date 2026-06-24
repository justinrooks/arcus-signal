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
                sbcapeJkg: 1900,
                mlcapeJkg: 2200,
                mucapeJkg: 2300,
                mlcinJkg: -35,
                mllclM: 850,
                temperatureDewpointSpreadF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
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
                mllclM: 1600,
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

    @Test("missing Anvil evidence preserves the baseline assessment")
    func missingAnvilEvidencePreservesBaselineAssessment() {
        let raw = makeRaw(
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

        let baseline = interpret(raw: raw)
        let withMissingEvidence = interpret(raw: raw, evidence: nil)

        #expect(withMissingEvidence.overall == baseline.overall)
        #expect(withMissingEvidence.confidence == baseline.confidence)
        #expect(withMissingEvidence.summary == baseline.summary)
    }

    @Test("healthy Anvil evidence can strengthen the overall setup")
    func healthyAnvilEvidenceCanStrengthenTheOverallSetup() {
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
            ),
            evidence: makeHealthyStrongEvidence()
        )

        #expect(assessment.overall == .supportive)
        #expect(assessment.confidence == .high)
        #expect(assessment.summary.contains("Anvil analysis reinforces the setup."))
        #expect(!assessment.summary.lowercased().contains("scp"))
        #expect(!assessment.summary.lowercased().contains("stp"))
        #expect(!assessment.summary.lowercased().contains("ship"))
    }

    @Test("healthy weak Anvil evidence can lower support")
    func healthyWeakAnvilEvidenceCanLowerSupport() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1900,
                mlcapeJkg: 2200,
                mucapeJkg: 2300,
                mlcinJkg: -35,
                mllclM: 850,
                temperatureDewpointSpreadF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            ),
            evidence: makeHealthyWeakEvidence()
        )

        #expect(assessment.overall == .conditional)
        #expect(assessment.confidence == .low)
        #expect(assessment.summary.contains("Anvil analysis is not reinforcing the setup."))
    }

    @Test("degraded Anvil evidence lowers confidence without inventing certainty")
    func degradedAnvilEvidenceLowersConfidenceWithoutInventingCertainty() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1900,
                mlcapeJkg: 2200,
                mucapeJkg: 2300,
                mlcinJkg: -35,
                mllclM: 850,
                temperatureDewpointSpreadF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            ),
            evidence: makeDegradedEvidence()
        )

        #expect(assessment.overall == .supportive)
        #expect(assessment.confidence == .low)
        #expect(assessment.summary.contains("Anvil analysis is degraded, so confidence is limited."))
    }

    @Test("unavailable Anvil evidence is reported as unavailable and degrades confidence")
    func unavailableAnvilEvidenceIsReportedAsUnavailableAndDegradesConfidence() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1900,
                mlcapeJkg: 2200,
                mucapeJkg: 2300,
                mlcinJkg: -35,
                mllclM: 850,
                temperatureDewpointSpreadF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            ),
            evidence: .unavailable(reason: "Anvil analysis provider is not configured.")
        )

        #expect(assessment.overall == .supportive)
        #expect(assessment.confidence == .low)
        #expect(assessment.summary.contains("Anvil analysis is unavailable, so confidence is limited."))
    }

    @Test("MLCAPE follows updated operational threshold bands")
    func mlcapeFollowsUpdatedOperationalThresholdBands() {
        #expect(interpret(raw: makeRaw(mlcapeJkg: 900)).instability == .weak)
        #expect(interpret(raw: makeRaw(mlcapeJkg: 1500)).instability == .conditional)
        #expect(interpret(raw: makeRaw(mlcapeJkg: 2200)).instability == .supportive)
        #expect(interpret(raw: makeRaw(mlcapeJkg: 2600)).instability == .strong)
    }

    @Test("0-6 km bulk shear follows updated knot threshold bands")
    func deepShearFollowsUpdatedOperationalThresholdBands() {
        #expect(interpret(raw: makeRaw(shear06kmKt: 25)).deepShear == .weak)
        #expect(interpret(raw: makeRaw(shear06kmKt: 32)).deepShear == .conditional)
        #expect(interpret(raw: makeRaw(shear06kmKt: 42)).deepShear == .supportive)
        #expect(interpret(raw: makeRaw(shear06kmKt: 52)).deepShear == .strong)
    }

    @Test("low-level rotation scores 0-1 km and 0-3 km SRH with separate bands")
    func lowLevelRotationUsesSeparateSRHBands() {
        #expect(interpret(raw: makeRaw(srh01kmM2s2: 90)).lowLevelRotation == .weak)
        #expect(interpret(raw: makeRaw(srh01kmM2s2: 125)).lowLevelRotation == .conditional)
        #expect(interpret(raw: makeRaw(srh01kmM2s2: 175)).lowLevelRotation == .supportive)
        #expect(interpret(raw: makeRaw(srh01kmM2s2: 225)).lowLevelRotation == .strong)

        #expect(interpret(raw: makeRaw(srh03kmM2s2: 140)).lowLevelRotation == .weak)
        #expect(interpret(raw: makeRaw(srh03kmM2s2: 200)).lowLevelRotation == .conditional)
        #expect(interpret(raw: makeRaw(srh03kmM2s2: 300)).lowLevelRotation == .supportive)
        #expect(interpret(raw: makeRaw(srh03kmM2s2: 375)).lowLevelRotation == .strong)
    }

    @Test("CIN uses an ideal middle range instead of monotonic scoring")
    func cinUsesIdealMiddleRange() {
        #expect(interpret(raw: makeRaw(mlcinJkg: -125)).capInhibition == .weak)
        #expect(interpret(raw: makeRaw(mlcinJkg: -85)).capInhibition == .conditional)
        #expect(interpret(raw: makeRaw(mlcinJkg: -50)).capInhibition == .strong)
        #expect(interpret(raw: makeRaw(mlcinJkg: -10)).capInhibition == .conditional)
    }

    @Test("LCL height follows updated cloud-base threshold bands")
    func lclHeightFollowsUpdatedCloudBaseThresholdBands() {
        #expect(interpret(raw: makeRaw(mllclM: 1600)).cloudBase == .weak)
        #expect(interpret(raw: makeRaw(mllclM: 1250)).cloudBase == .conditional)
        #expect(interpret(raw: makeRaw(mllclM: 900)).cloudBase == .supportive)
        #expect(interpret(raw: makeRaw(mllclM: 700)).cloudBase == .strong)
    }

    private func interpret(raw: TornadoRawParameters) -> TornadoIngredientAssessment {
        interpret(raw: raw, evidence: nil)
    }

    private func interpret(
        raw: TornadoRawParameters,
        evidence: AnvilIngredientEvidence?
    ) -> TornadoIngredientAssessment {
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
        return TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness, evidence: evidence)
    }

    private func makeHealthyStrongEvidence() -> AnvilIngredientEvidence {
        AnvilIngredientEvidence(response: AnvilAnalyzeProfileResponse(
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
                    uKt: 36.80394762849837,
                    vKt: 13.53066796460426,
                    speedKt: 39.21236458834915,
                    directionTowardDeg: 69.81446460119884,
                    uMs: 18.933570033795217,
                    vMs: 6.960770950382875,
                    speedMs: 20.172565688288692
                )
            ),
            mucape: 362.1018454649957,
            mlcape: 191.7304143918497,
            mlcin: -221.93726424748172,
            mllclMetersAgl: 1179.4130766012365,
            effectiveSrh: 29.42420403684148,
            effectiveBulkShearMs: 30.134722226263612,
            scp: 4.2,
            stpCin: 0.0,
            stpFixed: 3.4,
            ship: 2.3,
            quality: AnvilQualityDTO(
                profileLevelCount: 20,
                warnings: []
            )
        ))
    }

    private func makeHealthyWeakEvidence() -> AnvilIngredientEvidence {
        AnvilIngredientEvidence(response: AnvilAnalyzeProfileResponse(
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
                    uKt: 36.80394762849837,
                    vKt: 13.53066796460426,
                    speedKt: 39.21236458834915,
                    directionTowardDeg: 69.81446460119884,
                    uMs: 18.933570033795217,
                    vMs: 6.960770950382875,
                    speedMs: 20.172565688288692
                )
            ),
            mucape: 362.1018454649957,
            mlcape: 191.7304143918497,
            mlcin: -221.93726424748172,
            mllclMetersAgl: 1179.4130766012365,
            effectiveSrh: 29.42420403684148,
            effectiveBulkShearMs: 30.134722226263612,
            scp: 0.2,
            stpCin: 0.1,
            stpFixed: 0.3,
            ship: 0.1,
            quality: AnvilQualityDTO(
                profileLevelCount: 20,
                warnings: []
            )
        ))
    }

    private func makeDegradedEvidence() -> AnvilIngredientEvidence {
        AnvilIngredientEvidence(response: AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: "notFound",
                basePressureMb: nil,
                topPressureMb: nil,
                baseMetersAgl: nil,
                topMetersAgl: nil
            ),
            stormMotion: AnvilStormMotionDTO(
                status: "notComputed",
                bunkersRight: nil
            ),
            mucape: nil,
            mlcape: nil,
            mlcin: nil,
            mllclMetersAgl: nil,
            effectiveSrh: nil,
            effectiveBulkShearMs: nil,
            scp: nil,
            stpCin: nil,
            stpFixed: nil,
            ship: nil,
            quality: AnvilQualityDTO(
                profileLevelCount: 3,
                warnings: ["profile incomplete"]
            )
        ))
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
