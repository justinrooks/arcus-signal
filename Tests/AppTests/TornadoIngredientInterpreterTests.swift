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
                tempDewPtDeltaF: 24,
                shear06kmKt: 20,
                srh01kmM2s2: 40,
                srh03kmM2s2: 55
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .weak)
        #expect(report.details.stormViability == .weak)
        #expect(report.details.tornadoEfficiency == .weak)
        #expect(assessment.summary.contains("main limiting factor"))
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
                tempDewPtDeltaF: 17,
                shear06kmKt: 42,
                srh01kmM2s2: 90,
                srh03kmM2s2: 140
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .conditional)
        #expect(report.details.stormViability == .conditional)
        #expect(report.details.tornadoEfficiency == .weak)
        #expect(assessment.summary.contains("some ingredients for tornado-capable storms"))
        #expect(assessment.summary.contains("realization is conditional"))
    }

    @Test("canonical Anvil fields drive conditional tornado messaging when CIN still limits realization")
    func canonicalAnvilFieldsDriveConditionalTornadoMessaging() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 3200,
                mlcapeJkg: 1800,
                mucapeJkg: 2200,
                mlcinJkg: -95,
                mllclM: 950,
                tempDewPtDeltaF: 28,
                effectiveBulkShearMs: 22,
                shear06kmKt: 18,
                srh01kmM2s2: 40,
                srh03kmM2s2: 60,
                effectiveSrhM2s2: 175,
                supercellComposite: 2.4,
                significantTornadoFixed: 1.7,
                significantTornadoEffective: 0.9
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.instability == .supportive)
        #expect(assessment.cloudBase == .supportive)
        #expect(assessment.deepShear == .supportive)
        #expect(assessment.lowLevelRotation == .weak)
        #expect(assessment.compositeSignal == .conditional)
        #expect(assessment.capInhibition == .conditional)
        #expect(assessment.overall == .conditional)
        #expect(report.realization == .conditional)
        #expect(report.details.supercellComposite == .supportive)
        #expect(report.details.tornadoComposite == .conditional)
        #expect(assessment.summary.contains("some ingredients for tornado-capable storms"))
        #expect(assessment.summary.contains("The fixed-layer signal is stronger than the effective-layer signal"))
        #expect(assessment.summary.contains("the setup remains conditional"))
    }

    @Test("native diagnostics still drive the assessment when canonical fields are absent")
    func nativeDiagnosticsStillDriveAssessmentWhenCanonicalFieldsAreAbsent() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 1200,
                mlcinJkg: -35,
                tempDewPtDeltaF: 10,
                shear06kmKt: 45,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.instability == .conditional)
        #expect(assessment.cloudBase == .strong)
        #expect(assessment.deepShear == .supportive)
        #expect(assessment.lowLevelRotation == .weak)
        #expect(assessment.overall == .conditional)
        #expect(report.details.lowLevelRotation == .weak)
        #expect(report.details.lowLevelStretching == .unknown)
        #expect(report.details.tornadoEfficiency == .weak)
        #expect(assessment.summary.contains("some ingredients for tornado-capable storms"))
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
                tempDewPtDeltaF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .supportive)
        #expect(report.details.stormViability >= .supportive)
        #expect(report.details.tornadoEfficiency >= .supportive)
        #expect(assessment.summary.contains("can support organized rotating storms"))
        #expect(assessment.summary.contains("Stay weather-aware"))
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
                tempDewPtDeltaF: 6,
                shear06kmKt: 58,
                srh01kmM2s2: 260,
                srh03kmM2s2: 320,
                supercellComposite: 4.5,
                significantTornadoFixed: 3.1,
                significantTornadoEffective: 4.2
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .strong)
        #expect(assessment.compositeSignal == .strong)
        #expect(assessment.confidence == .high)
        #expect(report.realization == .realized)
        #expect(report.details.stormViability == .strong)
        #expect(report.details.supercellViability == .strong)
        #expect(report.details.tornadoEfficiency == .strong)
        #expect(assessment.summary.contains("strongly supports organized rotating storms"))
        #expect(assessment.summary.contains("not a guarantee storms will occur"))
    }

    @Test("low-level efficient setup keeps tornado efficiency strong even when the environment remains only supportive overall")
    func lowLevelEfficientSetupKeepsTornadoEfficiencyStrong() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2100,
                mlcapeJkg: 2300,
                mucapeJkg: 2400,
                mlcinJkg: -30,
                mllclM: 720,
                tempDewPtDeltaF: 8,
                shear06kmKt: 46,
                srh01kmM2s2: 225,
                threeCapeJkg: 165,
                supercellComposite: 2.1,
                significantTornadoFixed: 1.9,
                significantTornadoEffective: 2.2
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.details.lowLevelRotation == .strong)
        #expect(report.details.lowLevelStretching == .strong)
        #expect(report.details.cloudBaseEfficiency == .strong)
        #expect(report.details.tornadoEfficiency == .strong)
        #expect(assessment.overall == .supportive)
        #expect(assessment.summary.contains("Stay weather-aware"))
    }

    @Test("capped conditional setup stays conditional when fixed-layer STP outpaces effective-layer STP")
    func cappedConditionalSetupStaysConditional() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2500,
                mlcapeJkg: 2700,
                mucapeJkg: 2800,
                mlcinJkg: -40,
                mllclM: 860,
                tempDewPtDeltaF: 9,
                shear06kmKt: 52,
                srh01kmM2s2: 190,
                threeCapeJkg: 120,
                supercellComposite: 3.1,
                significantTornadoFixed: 3.6,
                significantTornadoEffective: 1.0
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.primaryFailureMode == .fixedEffectiveStpDisagreement)
        #expect(report.realization == .conditional)
        #expect(report.details.supercellComposite == .strong)
        #expect(report.details.tornadoComposite == .conditional)
        #expect(assessment.overall == .conditional)
        #expect(assessment.summary.contains("The fixed-layer signal is stronger than the effective-layer signal"))
    }

    @Test("missing core fields yields unknown and degraded confidence")
    func missingCoreFieldsYieldUnknownAndDegradedConfidence() {
        let assessment = interpret(raw: .empty)
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .unknown)
        #expect(assessment.confidence == .degraded)
        #expect(report.realization == .unknown)
        #expect(report.details.stormViability == .unknown)
        #expect(report.details.tornadoEfficiency == .unknown)
        #expect(assessment.summary.contains("not enough current ingredient data"))
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
                tempDewPtDeltaF: 12,
                shear06kmKt: 45,
                srh01kmM2s2: 45,
                srh03kmM2s2: 60
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .conditional)
        #expect(report.details.tornadoEfficiency == .weak)
        #expect(assessment.limitingFactors.contains(.weakLowLevelRotation))
    }

    @Test("weak SRH with adequate 3CAPE produces a low-level rotation limiter")
    func weakSrhWithAdequateThreeCapeProducesRotationLimiter() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -45,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 50,
                srh01kmM2s2: 60,
                threeCapeJkg: 120,
                supercellComposite: 2.8,
                significantTornadoFixed: 1.8,
                significantTornadoEffective: 1.4
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.details.lowLevelRotation == .weak)
        #expect(report.details.lowLevelStretching >= .supportive)
        #expect(report.limitingFactors.contains(.weakLowLevelRotation))
        #expect(!report.limitingFactors.contains(.weakLowLevelStretching))
    }

    @Test("adequate SRH with weak 3CAPE produces a low-level stretching limiter")
    func adequateSrhWithWeakThreeCapeProducesStretchingLimiter() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -45,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 50,
                srh01kmM2s2: 180,
                threeCapeJkg: 10,
                supercellComposite: 2.8,
                significantTornadoFixed: 1.8,
                significantTornadoEffective: 1.4
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.details.lowLevelRotation >= .supportive)
        #expect(report.details.lowLevelStretching == .weak)
        #expect(report.limitingFactors.contains(.weakLowLevelStretching))
        #expect(!report.limitingFactors.contains(.weakLowLevelRotation))
    }

    @Test("elevated cloud bases produce their own limiter")
    func elevatedCloudBasesProduceTheirOwnLimiter() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2200,
                mlcapeJkg: 2400,
                mucapeJkg: 2500,
                mlcinJkg: -40,
                mllclM: 1650,
                tempDewPtDeltaF: 23,
                shear06kmKt: 48,
                srh01kmM2s2: 170,
                threeCapeJkg: 100,
                supercellComposite: 2.4,
                significantTornadoFixed: 1.7,
                significantTornadoEffective: 1.2
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.details.cloudBaseEfficiency == .weak)
        #expect(report.limitingFactors.contains(.elevatedCloudBases))
    }

    @Test("strong CIN produces a strong-cap failure mode")
    func strongCinProducesStrongCapFailureMode() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2500,
                mlcapeJkg: 2700,
                mucapeJkg: 2800,
                mlcinJkg: -165,
                mllclM: 850,
                tempDewPtDeltaF: 9,
                shear06kmKt: 50,
                srh01kmM2s2: 185,
                threeCapeJkg: 120,
                supercellComposite: 3.2,
                significantTornadoFixed: 2.4,
                significantTornadoEffective: 2.1
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.primaryFailureMode == .strongCap)
        #expect(report.realization == .blocked)
        #expect(report.limitingFactors.contains(.strongCap))
    }

    @Test("moderate CIN with supportive ingredients stays conditional instead of becoming a strong cap")
    func moderateCinKeepsRealizationConditional() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2600,
                mucapeJkg: 2700,
                mlcinJkg: -90,
                mllclM: 850,
                tempDewPtDeltaF: 9,
                shear06kmKt: 52,
                srh01kmM2s2: 190,
                threeCapeJkg: 120,
                supercellComposite: 3.1,
                significantTornadoFixed: 2.3,
                significantTornadoEffective: 2.0
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.primaryFailureMode == .conditionalInitiation)
        #expect(report.realization == .conditional)
        #expect(report.limitingFactors.contains(.conditionalInitiation))
        #expect(!report.limitingFactors.contains(.strongCap))
    }

    @Test("fixed and effective STP disagreement can make realization conditional")
    func fixedAndEffectiveStpDisagreementCanMakeRealizationConditional() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2500,
                mlcapeJkg: 2700,
                mucapeJkg: 2800,
                mlcinJkg: -40,
                mllclM: 850,
                tempDewPtDeltaF: 9,
                shear06kmKt: 52,
                srh01kmM2s2: 190,
                threeCapeJkg: 120,
                supercellComposite: 3.1,
                significantTornadoFixed: 3.6,
                significantTornadoEffective: 1.0
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(report.primaryFailureMode == .fixedEffectiveStpDisagreement)
        #expect(report.realization == .conditional)
        #expect(report.limitingFactors.contains(.fixedEffectiveStpDisagreement))
    }

    @Test("missing storm-mode data stays unknown in the report")
    func missingStormModeDataStaysUnknownInTheReport() {
        let report = TornadoViabilityReport(assessment: interpret(raw: .empty))

        #expect(report.details.stormMode == .unknown)
        #expect(report.realization == .unknown)
        #expect(report.primaryFailureMode == .missingStormMode)
    }

    @Test("weak 0-1 km SRH limits tornado messaging even with elevated composite signals")
    func weakSrh01LimitsTornadoMessagingEvenWithElevatedCompositeSignals() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2600,
                mlcapeJkg: 2800,
                mucapeJkg: 3000,
                mlcinJkg: -35,
                mllclM: 850,
                tempDewPtDeltaF: 8,
                shear06kmKt: 52,
                srh01kmM2s2: 60,
                threeCapeJkg: 120,
                supercellComposite: 4.2,
                significantTornadoFixed: 3.2,
                significantTornadoEffective: 2.8
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.lowLevelRotation == .weak)
        #expect(assessment.overall == .conditional)
        #expect(report.details.supercellComposite == .strong)
        #expect(report.details.tornadoComposite == .strong)
        #expect(assessment.summary.contains("organized rotating storms"))
        #expect(assessment.summary.contains("tornado-specific low-level ingredients are limited"))
    }

    @Test("weak 0-3 km CAPE limits tornado messaging even with strong SRH")
    func weakThreeCapeLimitsTornadoMessagingEvenWithStrongSrh() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2200,
                mlcapeJkg: 2400,
                mucapeJkg: 2500,
                mlcinJkg: -30,
                mllclM: 900,
                tempDewPtDeltaF: 9,
                shear06kmKt: 48,
                srh01kmM2s2: 180,
                threeCapeJkg: 10,
                supercellComposite: 2.5,
                significantTornadoFixed: 1.8,
                significantTornadoEffective: 1.3
            )
        )

        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.lowLevelRotation == .weak)
        #expect(assessment.lowLevelStretching == .weak)
        #expect(assessment.tornadoEfficiency == .weak)
        #expect(report.limitingFactors.contains(.weakLowLevelStretching))
    }

    @Test("aligned low-level tornado ingredients increase concern without implying certainty")
    func alignedLowLevelTornadoIngredientsIncreaseConcern() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2000,
                mlcapeJkg: 2200,
                mucapeJkg: 2300,
                mlcinJkg: -35,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 46,
                srh01kmM2s2: 175,
                threeCapeJkg: 110,
                supercellComposite: 2.8,
                significantTornadoFixed: 1.9,
                significantTornadoEffective: 1.2
            )
        )

        #expect(assessment.lowLevelRotation >= .supportive)
        #expect(assessment.cloudBase >= .supportive)
        #expect(assessment.overall == .conditional)
        #expect(assessment.summary.contains("The fixed-layer signal is stronger than the effective-layer signal"))
    }

    @Test("diagnosis-backed reports preserve the internal diagnosis values")
    func diagnosisBackedReportsPreserveInternalDiagnosisValues() {
        let diagnosis = TornadoViabilityDiagnosis(
            stormViability: .supportive,
            supercellViability: .strong,
            lowLevelRotation: .conditional,
            lowLevelStretching: .supportive,
            cloudBaseEfficiency: .weak,
            tornadoEfficiency: .conditional,
            inhibition: .supportive,
            supercellComposite: .strong,
            compositeConfirmation: .conditional,
            realization: .conditional,
            failureMode: .fixedEffectiveStpDisagreement,
            confidence: .high,
            overall: .supportive,
            summary: "diagnosis summary",
            primaryDrivers: ["diagnosis driver"],
            limitingFactors: [.weakDeepShear, .poorMoisture],
            viabilityLimiters: [.weakDeepShear, .poorMoisture],
            instability: .strong,
            moisture: .conditional,
            cloudBase: .weak,
            capInhibition: .supportive,
            deepShear: .supportive,
            stormMode: .unknown,
            compositeSignal: .conditional
        )

        let report = TornadoViabilityReport(diagnosis: diagnosis)

        #expect(report.overall == .supportive)
        #expect(report.realization == .conditional)
        #expect(report.primaryFailureMode == .fixedEffectiveStpDisagreement)
        #expect(report.confidence == .high)
        #expect(report.summary == "diagnosis summary")
        #expect(report.details.stormViability == .supportive)
        #expect(report.details.supercellViability == .strong)
        #expect(report.details.tornadoEfficiency == .conditional)
        #expect(report.details.inhibition == .supportive)
        #expect(report.details.instability == .strong)
        #expect(report.details.moisture == .conditional)
        #expect(report.details.cloudBase == .weak)
        #expect(report.details.deepShear == .supportive)
        #expect(report.details.lowLevelRotation == .conditional)
        #expect(report.details.lowLevelStretching == .supportive)
        #expect(report.details.cloudBaseEfficiency == .weak)
        #expect(report.details.supercellComposite == .strong)
        #expect(report.details.tornadoComposite == .conditional)
        #expect(report.details.stormMode == .unknown)
        #expect(report.limitingFactors == [.weakDeepShear, .poorMoisture])
    }

    @Test("high SCP with weak STP stays limited to supercell support")
    func highScpWithWeakStpStaysLimitedToSupercellSupport() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -35,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 50,
                srh01kmM2s2: 170,
                threeCapeJkg: 110,
                supercellComposite: 3.2,
                significantTornadoFixed: 0.8,
                significantTornadoEffective: 0.9
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.compositeSignal == .conditional)
        #expect(assessment.overall != .strong)
        #expect(report.details.supercellComposite == .strong)
        #expect(report.details.tornadoComposite == .conditional)
        #expect(assessment.summary.contains("The environment can support organized rotating storms, but tornado-specific low-level ingredients are limited."))
    }

    @Test("STP mismatch and meaningful CIN keep the tornado wording conditional")
    func stpMismatchAndMeaningfulCinKeepTornadoWordingConditional() {
        let assessment = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -95,
                mllclM: 950,
                tempDewPtDeltaF: 11,
                shear06kmKt: 50,
                srh01kmM2s2: 170,
                threeCapeJkg: 115,
                supercellComposite: 2.6,
                significantTornadoFixed: 3.4,
                significantTornadoEffective: 0.9
            )
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .conditional)
        #expect(assessment.capInhibition == .conditional)
        #expect(report.primaryFailureMode == .fixedEffectiveStpDisagreement)
        #expect(assessment.summary.contains("The fixed-layer signal is stronger than the effective-layer signal"))
        #expect(assessment.summary.contains("the setup remains conditional"))
    }

    @Test("Anvil-backed canonical ingredients do not get raised twice by the same Anvil evidence")
    func anvilBackedCanonicalIngredientsDoNotGetRaisedTwice() {
        let raw = makeRaw(
            sbcapeJkg: 1450,
            mlcapeJkg: 191.7304143918497,
            mucapeJkg: 362.1018454649957,
            mlcinJkg: -221.93726424748172,
            mllclM: 1179.4130766012365,
            effectiveBulkShearMs: 30.134722226263612,
            srh01kmM2s2: 29.42420403684148,
            effectiveSrhM2s2: 29.42420403684148,
            supercellComposite: 4.2,
            significantTornadoFixed: 3.4,
            significantTornadoEffective: 0.0,
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
            )
        )

        let baseline = interpret(raw: raw)
        let withEvidence = interpret(raw: raw, evidence: makeHealthyStrongEvidence())

        #expect(withEvidence.overall == baseline.overall)
    }

    @Test("fallback still works when 0-1 km SRH or 0-3 km CAPE is missing")
    func missingLowLevelIngredientsStillFallback() {
        let onlySrh = interpret(
            raw: makeRaw(
                mlcapeJkg: 1900,
                mucapeJkg: 2000,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 44,
                srh01kmM2s2: 170
            )
        )

        let onlyThreeCape = interpret(
            raw: makeRaw(
                mlcapeJkg: 1900,
                mucapeJkg: 2000,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 44,
                threeCapeJkg: 105
            )
        )
        let report = TornadoViabilityReport(assessment: onlyThreeCape)

        #expect(onlySrh.lowLevelRotation != .unknown)
        #expect(onlySrh.lowLevelStretching == .unknown)
        #expect(onlyThreeCape.lowLevelRotation == .unknown)
        #expect(onlyThreeCape.lowLevelRotationSupport == .unknown)
        #expect(onlyThreeCape.lowLevelStretching == .supportive)
        #expect(onlyThreeCape.tornadoEfficiency == .unknown)
        #expect(report.details.lowLevelRotation == .unknown)
        #expect(report.details.lowLevelStretching == .supportive)
        #expect(report.details.tornadoEfficiency == .unknown)
    }

    @Test("strong cap limiting factor only appears at -150 CIN or weaker")
    func strongCapLimitTracksUpdatedCinThreshold() {
        let weakCap = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -110,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 45,
                srh01kmM2s2: 180
            )
        )

        let strongCap = interpret(
            raw: makeRaw(
                sbcapeJkg: 2400,
                mlcapeJkg: 2500,
                mucapeJkg: 2600,
                mlcinJkg: -150,
                mllclM: 900,
                tempDewPtDeltaF: 10,
                shear06kmKt: 45,
                srh01kmM2s2: 180
            )
        )

        #expect(!weakCap.limitingFactors.contains(.strongCap))
        #expect(strongCap.limitingFactors.contains(.strongCap))
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
                tempDewPtDeltaF: 24,
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
                tempDewPtDeltaF: 12,
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
                tempDewPtDeltaF: 17,
                shear06kmKt: 42,
                srh01kmM2s2: 90,
                srh03kmM2s2: 140
            )
        ).summary.lowercased()

        #expect(!summary.contains("tornadoes are likely"))
        #expect(!summary.contains("tornadoes will occur"))
        #expect(!summary.contains("probability"))
        #expect(!summary.contains("risk score"))
        #expect(!summary.contains("prediction"))
        #expect(!summary.contains("warning replacement"))
    }

    @Test("missing Anvil evidence preserves the baseline assessment")
    func missingAnvilEvidencePreservesBaselineAssessment() {
        let raw = makeRaw(
            sbcapeJkg: 1200,
            mlcapeJkg: 1300,
            mucapeJkg: 1500,
            mlcinJkg: -40,
            mllclM: 950,
            tempDewPtDeltaF: 17,
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
                tempDewPtDeltaF: 17,
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

    @Test("SHIP-only evidence does not raise tornado viability or confidence")
    func shipOnlyEvidenceDoesNotRaiseTornadoViabilityOrConfidence() {
        let raw = makeRaw(
            sbcapeJkg: 1200,
            mlcapeJkg: 1300,
            mucapeJkg: 1500,
            mlcinJkg: -40,
            mllclM: 950,
            tempDewPtDeltaF: 17,
            shear06kmKt: 42,
            srh01kmM2s2: 90,
            srh03kmM2s2: 140
        )

        let baseline = interpret(raw: raw)
        let withShipOnlyEvidence = interpret(raw: raw, evidence: makeShipOnlyEvidence())

        #expect(withShipOnlyEvidence.overall == baseline.overall)
        #expect(withShipOnlyEvidence.confidence == baseline.confidence)
        #expect(withShipOnlyEvidence.summary == baseline.summary + " Anvil analysis is not reinforcing the setup.")
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
                tempDewPtDeltaF: 10,
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
                tempDewPtDeltaF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            ),
            evidence: makeDegradedEvidence()
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .supportive)
        #expect(report.confidence == .low)
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
                tempDewPtDeltaF: 10,
                shear06kmKt: 48,
                srh01kmM2s2: 175,
                srh03kmM2s2: 300
            ),
            evidence: .unavailable(reason: "Anvil analysis provider is not configured.")
        )
        let report = TornadoViabilityReport(assessment: assessment)

        #expect(assessment.overall == .supportive)
        #expect(report.confidence == .low)
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

    @Test("0-1 km SRH takes priority over effective SRH")
    func srh01TakesPriorityOverEffectiveSrh() {
        let assessment = interpret(
            raw: makeRaw(
                srh01kmM2s2: 45,
                srh03kmM2s2: 375,
                effectiveSrhM2s2: 325
            )
        )

        #expect(assessment.lowLevelRotation == .weak)
    }

    @Test("effective SRH follows its own threshold bands")
    func effectiveSrhFollowsOwnThresholdBands() {
        #expect(interpret(raw: makeRaw(effectiveSrhM2s2: 90)).lowLevelRotation == .weak)
        #expect(interpret(raw: makeRaw(effectiveSrhM2s2: 150)).lowLevelRotation == .conditional)
        #expect(interpret(raw: makeRaw(effectiveSrhM2s2: 250)).lowLevelRotation == .supportive)
        #expect(interpret(raw: makeRaw(effectiveSrhM2s2: 320)).lowLevelRotation == .strong)
    }

    @Test("CIN uses the updated favorable weak-inhibition bands")
    func cinUsesIdealMiddleRange() {
        #expect(interpret(raw: makeRaw(mlcinJkg: -160)).capInhibition == .weak)
        #expect(interpret(raw: makeRaw(mlcinJkg: -100)).capInhibition == .conditional)
        #expect(interpret(raw: makeRaw(mlcinJkg: -50)).capInhibition == .supportive)
        #expect(interpret(raw: makeRaw(mlcinJkg: -10)).capInhibition == .strong)
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

    private func makeShipOnlyEvidence() -> AnvilIngredientEvidence {
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
            scp: nil,
            stpCin: nil,
            stpFixed: nil,
            ship: 2.3,
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
        tempDewPtDeltaF: Double? = nil,
        effectiveBulkShearMs: Double? = nil,
        shear06kmKt: Double? = nil,
        effectiveShearKt: Double? = nil,
        srh01kmM2s2: Double? = nil,
        srh03kmM2s2: Double? = nil,
        threeCapeJkg: Double? = nil,
        effectiveSrhM2s2: Double? = nil,
        supercellComposite: Double? = nil,
        significantTornadoFixed: Double? = nil,
        significantTornadoEffective: Double? = nil,
        effectiveLayer: AnvilEffectiveLayerDTO? = nil,
        stormMotion: AnvilStormMotionDTO? = nil
    ) -> TornadoRawParameters {
        TornadoRawParameters(
            sbcapeJkg: sbcapeJkg,
            mlcapeJkg: mlcapeJkg,
            mucapeJkg: mucapeJkg,
            mlcinJkg: mlcinJkg,
            dcapeJkg: nil,
            mllclM: mllclM,
            tempDewPtDeltaF: tempDewPtDeltaF,
            threeCapeJkg: threeCapeJkg,
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
            diagnostics: nil,
            effectiveBulkShearMs: effectiveBulkShearMs,
            effectiveLayer: effectiveLayer,
            stormMotion: stormMotion
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
