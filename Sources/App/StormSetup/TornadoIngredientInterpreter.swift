import Foundation
import Vapor

struct TornadoIngredientInterpreter: Sendable {
    private let rulesVersion: StormSetupRulesVersion

    init(rulesVersion: StormSetupRulesVersion = .current) {
        self.rulesVersion = rulesVersion
    }

    func assess(raw: TornadoRawParameters, freshness: IngredientFreshness) -> TornadoIngredientAssessment {
        assess(raw: raw, freshness: freshness, evidence: nil)
    }

    func assess(
        raw: TornadoRawParameters,
        freshness: IngredientFreshness,
        evidence anvilEvidence: AnvilIngredientEvidence?
    ) -> TornadoIngredientAssessment {
        let diagnosis = diagnose(raw: raw, freshness: freshness, evidence: anvilEvidence)

        return TornadoIngredientAssessment(
            overall: diagnosis.overall,
            instability: diagnosis.instability,
            moisture: diagnosis.moisture,
            cloudBase: diagnosis.cloudBase,
            capInhibition: diagnosis.capInhibition,
            deepShear: diagnosis.deepShear,
            lowLevelRotation: diagnosis.tornadoEfficiency,
            stormMode: diagnosis.stormMode,
            compositeSignal: diagnosis.compositeSignal,
            confidence: diagnosis.confidence,
            trend: .unknown,
            stormModeHint: .unknown,
            primaryDrivers: diagnosis.primaryDrivers,
            limitingFactors: diagnosis.limitingFactors,
            summary: diagnosis.summary,
            lowLevelRotationSupport: diagnosis.lowLevelRotation,
            lowLevelStretching: diagnosis.lowLevelStretching,
            cloudBaseEfficiency: diagnosis.cloudBaseEfficiency,
            tornadoEfficiency: diagnosis.tornadoEfficiency,
            stormViability: diagnosis.stormViability,
            supercellViability: diagnosis.supercellViability,
            supercellComposite: diagnosis.supercellComposite,
            realization: diagnosis.realization,
            primaryFailureMode: diagnosis.failureMode,
            viabilityLimiters: diagnosis.viabilityLimiters
        )
    }

    private func diagnose(
        raw: TornadoRawParameters,
        freshness: IngredientFreshness,
        evidence anvilEvidence: AnvilIngredientEvidence?
    ) -> TornadoViabilityDiagnosis {
        let instability = assessInstability(raw)
        let moisture = assessMoisture(raw)
        let cloudBase = assessCloudBase(raw)
        let capInhibition = assessCapInhibition(raw)
        let deepShear = assessDeepShear(raw)
        let lowLevelRotation = assessLowLevelRotation(raw)
        let lowLevelStretching = assessLowLevelStretching(raw)
        let cloudBaseEfficiency = assessCloudBaseEfficiency(raw)
        let supercellSupport = assessSupercellSupport(raw)
        let tornadoComposite = assessTornadoCompositeSupport(raw)
        let compositeConfirmation = assessCompositeConfirmation(
            supercellSupport: supercellSupport,
            tornadoComposite: tornadoComposite
        )
        let stormMode = assessStormMode()
        let stormViability = assessStormViability(
            instability: instability,
            moisture: moisture,
            deepShear: deepShear
        )
        let supercellViability = assessSupercellViability(
            instability: instability,
            deepShear: deepShear,
            supercellSupport: supercellSupport
        )
        let tornadoEfficiency = assessTornadoEfficiency(
            lowLevelRotation: lowLevelRotation,
            lowLevelStretching: lowLevelStretching,
            cloudBaseEfficiency: cloudBaseEfficiency
        )

        let knownCorePillars = [
            instability,
            deepShear,
            tornadoEfficiency,
            cloudBase,
            supercellSupport
        ].filter { $0 != .unknown }.count

        let viabilityLimiters = makeViabilityLimiters(
            raw: raw,
            instability: instability,
            moisture: moisture,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
            lowLevelStretching: lowLevelStretching,
            cloudBaseEfficiency: cloudBaseEfficiency,
            stormMode: stormMode,
            supercellSupport: supercellSupport,
            tornadoComposite: tornadoComposite
        )

        let limitingFactors = makeLimitingFactors(
            raw: raw,
            instability: instability,
            moisture: moisture,
            cloudBase: cloudBase,
            capInhibition: capInhibition,
            deepShear: deepShear,
            lowLevelRotation: tornadoEfficiency,
            stormMode: stormMode,
            compositeSignal: tornadoComposite
        )

        let baselineOverall = assessOverall(
            instability: instability,
            cloudBase: cloudBase,
            deepShear: deepShear,
            lowLevelRotation: tornadoEfficiency,
            supercellSupport: supercellSupport,
            compositeSignal: tornadoComposite,
            capInhibition: capInhibition,
            knownCorePillars: knownCorePillars
        )

        let baselineConfidence = assessConfidence(freshness: freshness, knownCorePillars: knownCorePillars)
        let evidenceAdjusted = assessAnvilEvidence(
            raw: raw,
            rawOverall: baselineOverall,
            rawConfidence: baselineConfidence,
            freshness: freshness,
            knownCorePillars: knownCorePillars,
            evidence: anvilEvidence
        )
        let failureMode = assessFailureMode(
            limitingFactors: limitingFactors,
            viabilityLimiters: viabilityLimiters,
            supercellSupport: supercellSupport,
            tornadoComposite: tornadoComposite,
            compositeConfirmation: compositeConfirmation
        )

        return TornadoViabilityDiagnosis(
            stormViability: stormViability,
            supercellViability: supercellViability,
            lowLevelRotation: lowLevelRotation,
            lowLevelStretching: lowLevelStretching ?? .unknown,
            cloudBaseEfficiency: cloudBaseEfficiency ?? .unknown,
            tornadoEfficiency: tornadoEfficiency,
            inhibition: capInhibition,
            supercellComposite: supercellSupport,
            compositeConfirmation: compositeConfirmation,
            realization: assessRealization(
                overall: evidenceAdjusted.overall,
                tornadoEfficiency: tornadoEfficiency,
                inhibition: capInhibition,
                viabilityLimiters: viabilityLimiters
            ),
            failureMode: failureMode,
            confidence: evidenceAdjusted.confidence,
            overall: evidenceAdjusted.overall,
            summary: makeSummary(
                overall: evidenceAdjusted.overall,
                raw: raw,
                limitingFactors: limitingFactors,
                failureMode: failureMode,
                capInhibition: capInhibition,
                cloudBase: cloudBase,
                lowLevelRotation: lowLevelRotation,
                supercellSupport: supercellSupport,
                compositeSignal: tornadoComposite,
                anvilEvidence: anvilEvidence
            ),
            primaryDrivers: makePrimaryDrivers(
                instability: instability,
                moisture: moisture,
                cloudBase: cloudBase,
                capInhibition: capInhibition,
                deepShear: deepShear,
                lowLevelRotation: tornadoEfficiency,
                lowLevelStretching: lowLevelStretching,
                supercellSupport: supercellSupport,
                supercellComposite: supercellSupport,
                compositeSignal: tornadoComposite
            ),
            limitingFactors: limitingFactors,
            viabilityLimiters: viabilityLimiters,
            instability: instability,
            moisture: moisture,
            cloudBase: cloudBase,
            capInhibition: capInhibition,
            deepShear: deepShear,
            stormMode: stormMode,
            compositeSignal: tornadoComposite
        )
    }

    private func assessInstability(_ raw: TornadoRawParameters) -> IngredientSupport {
        let values = [raw.mlcapeJkg, raw.mucapeJkg].compactMap { $0 }
        if let strongest = values.max() {
            return assessInstabilityValue(strongest)
        }

        guard let sbcape = raw.sbcapeJkg else {
            return .unknown
        }

        return assessInstabilityValue(sbcape)
    }

    private func assessInstabilityValue(_ strongest: Double) -> IngredientSupport {
        switch strongest {
        case ..<1000:
            return .weak
        case ..<2000:
            return .conditional
        case ..<2500:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessMoisture(_ raw: TornadoRawParameters) -> IngredientSupport {
        guard let score = moistureScore(raw) else {
            return .unknown
        }

        switch score {
        case ..<0.25:
            return .weak
        case ..<0.5:
            return .conditional
        case ..<0.75:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessCloudBase(_ raw: TornadoRawParameters) -> IngredientSupport {
        guard let score = cloudBaseScore(raw) else {
            return .unknown
        }

        switch score {
        case ..<0.25:
            return .weak
        case ..<0.5:
            return .conditional
        case ..<0.75:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessCapInhibition(_ raw: TornadoRawParameters) -> IngredientSupport {
        guard let cin = raw.mlcinJkg else {
            return .unknown
        }

        switch cin {
        case ..<(-150):
            return .weak
        case ..<(-75):
            return .conditional
        case ..<(-25):
            return .supportive
        default:
            return .strong
        }
    }

    private func assessDeepShear(_ raw: TornadoRawParameters) -> IngredientSupport {
        if let effectiveBulkShearMs = raw.effectiveBulkShearMs {
            return assessDeepShearValue(effectiveBulkShearMs * 1.943_844_492_440_6)
        }

        let values = [raw.effectiveShearKt, raw.shear06kmKt].compactMap { $0 }
        guard let strongest = values.max() else {
            return .unknown
        }

        return assessDeepShearValue(strongest)
    }

    private func assessDeepShearValue(_ strongest: Double) -> IngredientSupport {
        switch strongest {
        case ..<30:
            return .weak
        case ..<35:
            return .conditional
        case ..<50:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessLowLevelRotation(_ raw: TornadoRawParameters) -> IngredientSupport {
        if let srh01kmM2s2 = raw.srh01kmM2s2 {
            return assessSRH01km(srh01kmM2s2)
        }

        if let effectiveSrh = raw.effectiveSrhM2s2 {
            return assessEffectiveSRH(effectiveSrh)
        }

        if let srh03kmM2s2 = raw.srh03kmM2s2 {
            return assessSRH03km(srh03kmM2s2)
        }

        return .unknown
    }

    private func assessLowLevelStretching(_ raw: TornadoRawParameters) -> IngredientSupport? {
        raw.threeCapeJkg.map(assessThreeCape)
    }

    private func assessCloudBaseEfficiency(_ raw: TornadoRawParameters) -> IngredientSupport? {
        cloudBaseSupport(raw)
    }

    private func assessSupercellSupport(_ raw: TornadoRawParameters) -> IngredientSupport {
        guard let value = raw.supercellComposite else {
            return .unknown
        }

        switch value {
        case ..<0.5:
            return .weak
        case ..<1.5:
            return .conditional
        case ..<3:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessCompositeConfirmation(
        supercellSupport: IngredientSupport,
        tornadoComposite: IngredientSupport
    ) -> IngredientSupport {
        min(supercellSupport, tornadoComposite)
    }

    private func assessStormViability(
        instability: IngredientSupport,
        moisture: IngredientSupport,
        deepShear: IngredientSupport
    ) -> IngredientSupport {
        combineSupport(instability, moisture, deepShear)
    }

    private func assessSupercellViability(
        instability: IngredientSupport,
        deepShear: IngredientSupport,
        supercellSupport: IngredientSupport
    ) -> IngredientSupport {
        combineSupport(instability, deepShear, supercellSupport)
    }

    private func assessTornadoEfficiency(
        lowLevelRotation: IngredientSupport,
        lowLevelStretching: IngredientSupport?,
        cloudBaseEfficiency: IngredientSupport?
    ) -> IngredientSupport {
        combineSupport(lowLevelRotation, lowLevelStretching, cloudBaseEfficiency)
    }

    private func makeViabilityLimiters(
        raw: TornadoRawParameters,
        instability: IngredientSupport,
        moisture: IngredientSupport,
        deepShear: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        lowLevelStretching: IngredientSupport?,
        cloudBaseEfficiency: IngredientSupport?,
        stormMode: IngredientSupport,
        supercellSupport: IngredientSupport,
        tornadoComposite: IngredientSupport
    ) -> [TornadoViabilityLimiter] {
        var factors: [TornadoViabilityLimiter] = []
        var seen = Set<TornadoViabilityLimiter>()

        func append(_ factor: TornadoViabilityLimiter) {
            guard seen.insert(factor).inserted else {
                return
            }
            factors.append(factor)
        }

        if instability == .weak {
            append(.weakInstability)
        }
        if deepShear == .weak {
            append(.weakDeepShear)
        }
        if lowLevelRotation == .weak {
            append(.weakLowLevelRotation)
        }
        if let lowLevelStretching, lowLevelStretching == .weak, lowLevelRotation >= .conditional {
            append(.weakLowLevelStretching)
        }
        if let cloudBaseEfficiency, cloudBaseEfficiency == .weak {
            append(.elevatedCloudBases)
        }
        if let cin = raw.mlcinJkg {
            if cin <= -150 {
                append(.strongCap)
            } else if cin < -75 {
                append(.conditionalInitiation)
            }
        }
        if supercellSupport == .weak {
            append(.weakStormOrganization)
        }
        if let fixed = raw.significantTornadoFixed,
           let effective = raw.significantTornadoEffective,
           fixed >= 1.5,
           effective + 0.5 < fixed {
            append(.fixedEffectiveStpDisagreement)
        }
        if moisture == .weak {
            append(.poorMoisture)
        }
        if tornadoComposite == .weak, factors.isEmpty {
            append(.unknown)
        } else if stormMode == .unknown, factors.isEmpty {
            append(.missingStormMode)
        }

        return factors
    }

    private func assessSRH01km(_ value: Double) -> IngredientSupport {
        switch value {
        case ..<100:
            return .weak
        case ..<150:
            return .conditional
        case ..<200:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessSRH03km(_ value: Double) -> IngredientSupport {
        switch value {
        case ..<150:
            return .weak
        case ..<250:
            return .conditional
        case ..<350:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessEffectiveSRH(_ value: Double) -> IngredientSupport {
        switch value {
        case ..<100:
            return .weak
        case ..<200:
            return .conditional
        case ..<300:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessThreeCape(_ value: Double) -> IngredientSupport {
        switch value {
        case ..<25:
            return .weak
        case ..<75:
            return .conditional
        case ..<150:
            return .supportive
        default:
            return .strong
        }
    }

    private func cloudBaseSupport(_ raw: TornadoRawParameters) -> IngredientSupport? {
        guard let score = cloudBaseScore(raw) else {
            return nil
        }

        switch score {
        case ..<0.25:
            return .weak
        case ..<0.5:
            return .conditional
        case ..<0.75:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessStormMode() -> IngredientSupport {
        let _ = rulesVersion
        return .unknown
    }

    private func assessTornadoCompositeSupport(_ raw: TornadoRawParameters) -> IngredientSupport {
        if let effective = raw.significantTornadoEffective {
            return assessTornadoCompositeValue(effective)
        }

        if let fixed = raw.significantTornadoFixed {
            return assessTornadoCompositeValue(fixed)
        }

        return .unknown
    }

    private func assessTornadoCompositeValue(_ value: Double) -> IngredientSupport {
        switch value {
        case ..<0.5:
            return .weak
        case ..<1.25:
            return .conditional
        case ..<2.5:
            return .supportive
        default:
            return .strong
        }
    }

    private func assessOverall(
        instability: IngredientSupport,
        cloudBase: IngredientSupport,
        deepShear: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        supercellSupport: IngredientSupport,
        compositeSignal: IngredientSupport,
        capInhibition: IngredientSupport,
        knownCorePillars: Int
    ) -> IngredientSupport {
        guard knownCorePillars >= 4 else {
            return .unknown
        }

        if instability == .weak || deepShear == .weak || cloudBase == .weak {
            return .weak
        }

        let strongAgreementCount = [
            instability,
            deepShear,
            lowLevelRotation,
            cloudBase,
            supercellSupport,
            compositeSignal
        ].filter { $0 == .strong }.count

        if instability >= .supportive,
           deepShear >= .supportive,
           lowLevelRotation >= .supportive,
           cloudBase >= .supportive,
           supercellSupport >= .supportive,
           compositeSignal >= .supportive,
           strongAgreementCount >= 3 {
            return .strong
        }

        if instability >= .supportive,
           deepShear >= .supportive,
           lowLevelRotation >= .conditional,
           cloudBase >= .supportive,
           supercellSupport >= .conditional,
           compositeSignal >= .conditional,
           capInhibition <= .conditional {
            return .conditional
        }

        if instability >= .supportive,
           deepShear >= .supportive,
           cloudBase >= .supportive,
           supercellSupport >= .supportive,
           compositeSignal <= .conditional {
            return .conditional
        }

        if instability >= .supportive,
           deepShear >= .supportive,
           lowLevelRotation >= .conditional,
           cloudBase >= .supportive,
           compositeSignal >= .conditional,
           capInhibition <= .conditional {
            return .conditional
        }

        if instability >= .supportive,
           deepShear >= .supportive,
           cloudBase >= .supportive,
           lowLevelRotation <= .conditional {
            return .conditional
        }

        if instability >= .supportive,
           deepShear >= .supportive,
           lowLevelRotation >= .supportive,
           cloudBase >= .supportive {
            return .supportive
        }

        if instability >= .conditional,
           deepShear >= .conditional {
            return .conditional
        }

        return .weak
    }

    private func assessRealization(
        overall: IngredientSupport,
        tornadoEfficiency: IngredientSupport,
        inhibition: IngredientSupport,
        viabilityLimiters: [TornadoViabilityLimiter]
    ) -> TornadoViabilityRealization {
        if viabilityLimiters.contains(.strongCap) {
            return .blocked
        }
        if viabilityLimiters.contains(.conditionalInitiation) ||
            viabilityLimiters.contains(.fixedEffectiveStpDisagreement) {
            return .conditional
        }

        switch overall {
        case .unknown:
            return .unknown
        case .weak:
            return .blocked
        case .conditional:
            if inhibition <= .conditional {
                return .conditional
            }

            return tornadoEfficiency >= .supportive ? .conditional : .blocked
        case .supportive:
            if inhibition <= .conditional {
                return .conditional
            }

            return .realized
        case .strong:
            return .realized
        }
    }

    private func assessFailureMode(
        limitingFactors: [TornadoLimitingFactor],
        viabilityLimiters: [TornadoViabilityLimiter],
        supercellSupport: IngredientSupport,
        tornadoComposite: IngredientSupport,
        compositeConfirmation: IngredientSupport
    ) -> TornadoViabilityFailureMode {
        if viabilityLimiters.contains(.strongCap) {
            return .strongCap
        }
        if viabilityLimiters.contains(.fixedEffectiveStpDisagreement) {
            return .fixedEffectiveStpDisagreement
        }
        if viabilityLimiters.contains(.conditionalInitiation) {
            return .conditionalInitiation
        }
        if viabilityLimiters.contains(.weakStormOrganization) {
            return .weakStormOrganization
        }
        if viabilityLimiters.contains(.weakLowLevelStretching) {
            return .weakLowLevelStretching
        }
        if viabilityLimiters.contains(.missingStormMode) {
            return .missingStormMode
        }
        if limitingFactors.contains(.weakInstability) {
            return .weakInstability
        }
        if limitingFactors.contains(.weakDeepShear) {
            return .weakDeepShear
        }
        if limitingFactors.contains(.weakLowLevelRotation) {
            return .weakLowLevelRotation
        }
        if limitingFactors.contains(.elevatedCloudBases) {
            return .elevatedCloudBases
        }
        if limitingFactors.contains(.weakLift) {
            return .conditionalInitiation
        }
        if limitingFactors.contains(.poorMoisture) {
            return .poorMoisture
        }
        if supercellSupport >= .supportive, tornadoComposite <= .conditional, compositeConfirmation <= .conditional {
            return .compositeMismatch
        }
        if limitingFactors.contains(.messyStormMode) {
            return .messyStormMode
        }

        return .none
    }

    private func assessConfidence(
        freshness: IngredientFreshness,
        knownCorePillars: Int
    ) -> SnapshotConfidence {
        if freshness.isDegraded {
            return .degraded
        }

        switch knownCorePillars {
        case ...2:
            return .degraded
        case 3:
            return .low
        case 4:
            return .moderate
        default:
            return .high
        }
    }

    private func makePrimaryDrivers(
        instability: IngredientSupport,
        moisture: IngredientSupport,
        cloudBase: IngredientSupport,
        capInhibition: IngredientSupport,
        deepShear: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        lowLevelStretching: IngredientSupport?,
        supercellSupport: IngredientSupport,
        supercellComposite: IngredientSupport,
        compositeSignal: IngredientSupport
    ) -> [String] {
        var drivers: [String] = []

        if instability >= .supportive {
            drivers.append("Instability is supportive.")
        }
        if deepShear >= .supportive {
            drivers.append("Deep shear is supportive.")
        }
        if lowLevelRotation == .supportive || lowLevelRotation == .strong {
            drivers.append("Low-level tornado ingredients are supportive.")
        }
        if lowLevelStretching == .supportive || lowLevelStretching == .strong {
            drivers.append("Low-level stretching is supportive.")
        }
        if cloudBase >= .supportive {
            drivers.append("Cloud bases are favorable.")
        }
        if supercellSupport >= .supportive {
            drivers.append("Supercell organization is supportive.")
        }
        if supercellComposite >= .supportive {
            drivers.append("Supercell composite support is present.")
        }
        if compositeSignal >= .supportive {
            drivers.append("Tornado composite guidance is supportive.")
        }
        if moisture >= .supportive {
            drivers.append("Near-surface moisture is supportive.")
        }
        if capInhibition >= .supportive {
            drivers.append("Cap inhibition is manageable.")
        }

        return Array(drivers.prefix(3))
    }

    private func makeLimitingFactors(
        raw: TornadoRawParameters,
        instability: IngredientSupport,
        moisture: IngredientSupport,
        cloudBase: IngredientSupport,
        capInhibition: IngredientSupport,
        deepShear: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        stormMode: IngredientSupport,
        compositeSignal: IngredientSupport
    ) -> [TornadoLimitingFactor] {
        var factors: [TornadoLimitingFactor] = []
        var seen = Set<TornadoLimitingFactor>()

        func append(_ factor: TornadoLimitingFactor) {
            guard seen.insert(factor).inserted else {
                return
            }
            factors.append(factor)
        }

        if instability == .weak {
            append(.weakInstability)
        }
        if deepShear == .weak {
            append(.weakDeepShear)
        }
        if lowLevelRotation == .weak {
            append(.weakLowLevelRotation)
        }
        if let mllcl = raw.mllclM, mllcl > 1500 {
            append(.elevatedCloudBases)
        }
        if let cin = raw.mlcinJkg, cin <= -150 {
            append(.strongCap)
        } else if let cin = raw.mlcinJkg, cin < -75, instability >= .supportive, deepShear >= .supportive {
            append(.weakLift)
        }
        if moisture == .weak {
            append(.poorMoisture)
        }
        if compositeSignal == .weak, factors.isEmpty {
            append(.unknown)
        }

        return factors
    }

    private func makeSummary(
        overall: IngredientSupport,
        raw: TornadoRawParameters,
        limitingFactors: [TornadoLimitingFactor],
        failureMode: TornadoViabilityFailureMode,
        capInhibition: IngredientSupport,
        cloudBase: IngredientSupport,
        lowLevelRotation: IngredientSupport,
        supercellSupport: IngredientSupport,
        compositeSignal: IngredientSupport,
        anvilEvidence: AnvilIngredientEvidence?
    ) -> String {
        let baseSummary: String

        switch overall {
        case .weak:
            baseSummary = "The nearby environment does not currently support tornado-capable storms well."
        case .conditional:
            baseSummary = "The nearby environment has some ingredients for tornado-capable storms, but realization is conditional."
        case .supportive:
            baseSummary = "The nearby environment can support organized rotating storms, and low-level tornado ingredients are favorable."
        case .strong:
            baseSummary = "The nearby environment strongly supports organized rotating storms, and low-level tornado ingredients are aligned."
        case .unknown:
            baseSummary = "There is not enough current ingredient data to judge tornado formation viability confidently."
        }

        let limiterSentence = makeSummaryLimiterSentence(
            overall: overall,
            failureMode: failureMode,
            limitingFactors: limitingFactors,
            raw: raw,
            lowLevelRotation: lowLevelRotation,
            supercellSupport: supercellSupport,
            compositeSignal: compositeSignal
        )
        let capabilitySentence = makeSummaryCapabilitySentence(overall: overall)
        let summary = [baseSummary, limiterSentence, capabilitySentence]
            .compactMap { $0 }
            .joined(separator: " ")

        guard let anvilEvidence else {
            return summary
        }

        return summary + " " + makeAnvilEvidenceSummaryClause(anvilEvidence)
    }

    private func makeSummaryLimiterSentence(
        overall: IngredientSupport,
        failureMode: TornadoViabilityFailureMode,
        limitingFactors: [TornadoLimitingFactor],
        raw: TornadoRawParameters,
        lowLevelRotation: IngredientSupport,
        supercellSupport: IngredientSupport,
        compositeSignal: IngredientSupport
    ) -> String? {
        if overall == .weak {
            if limitingFactors.contains(.weakInstability) {
                return "Instability is the main limiting factor."
            }
            if limitingFactors.contains(.weakDeepShear) {
                return "Deep shear is the main limiting factor."
            }
            if limitingFactors.contains(.weakLowLevelRotation) {
                return "Low-level rotation is the main limiting factor."
            }
            if limitingFactors.contains(.elevatedCloudBases) {
                return "Elevated cloud bases are the main limiting factor."
            }
            if limitingFactors.contains(.poorMoisture) {
                return "Near-surface moisture is the main limiting factor."
            }
            if limitingFactors.contains(.messyStormMode) {
                return "Storm organization support is the main limiting factor."
            }
            return nil
        }

        if failureMode == .fixedEffectiveStpDisagreement {
            return "The fixed-layer signal is stronger than the effective-layer signal, so the setup remains conditional."
        }
        if overall == .conditional,
           supercellSupport >= .supportive,
           (lowLevelRotation <= .conditional || compositeSignal <= .conditional) {
            return "The environment can support organized rotating storms, but tornado-specific low-level ingredients are limited."
        }

        if failureMode == .strongCap {
            return "CIN may keep the setup from realizing."
        }
        if failureMode == .conditionalInitiation || failureMode == .weakLift {
            return "Storm initiation remains the main question."
        }
        if failureMode == .elevatedCloudBases {
            return "Elevated cloud bases reduce tornado efficiency."
        }
        if failureMode == .weakLowLevelStretching {
            return "Weak low-level buoyancy limits stretching near the ground."
        }
        if failureMode == .weakStormOrganization {
            return "Storm organization support is limited."
        }
        if failureMode == .poorMoisture {
            return "Near-surface moisture is limited."
        }
        if failureMode == .weakInstability {
            return "Instability is limited."
        }
        if failureMode == .weakDeepShear {
            return "Deep shear is limited."
        }
        if failureMode == .messyStormMode {
            return "Storm mode is too messy for a confident call."
        }
        if failureMode == .missingStormMode {
            return "Storm mode is not resolved from the current data."
        }
        if failureMode == .compositeMismatch {
            return "The composite signals do not fully agree."
        }

        if let fixed = raw.significantTornadoFixed,
           let effective = raw.significantTornadoEffective,
           fixed >= 1.5,
           effective + 0.5 < fixed {
            return "The fixed-layer signal is stronger than the effective-layer signal, so the setup remains conditional."
        }

        if overall == .conditional, supercellSupport >= .supportive, lowLevelRotation <= .conditional {
            return "The environment can support organized rotating storms, but tornado-specific low-level ingredients are limited."
        }

        return nil
    }

    private func makeSummaryCapabilitySentence(overall: IngredientSupport) -> String? {
        switch overall {
        case .supportive:
            return "Stay weather-aware if storms can form."
        case .strong:
            return "This describes environmental capability, not a guarantee storms will occur."
        default:
            return nil
        }
    }

    private func makeAnvilEvidenceSummaryClause(_ evidence: AnvilIngredientEvidence) -> String {
        if evidence.status == .unavailable {
            return "Anvil analysis is unavailable, so confidence is limited."
        }

        if evidence.isDegraded {
            return "Anvil analysis is degraded, so confidence is limited."
        }

        guard let strongestSupport = evidence.tornadoStrongestSupport else {
            return evidence.strongestSupport == nil ? "Anvil analysis is not available." : "Anvil analysis is not reinforcing the setup."
        }

        switch strongestSupport {
        case .weak:
            return "Anvil analysis is not reinforcing the setup."
        case .conditional:
            return "Anvil analysis is only modestly supportive."
        case .supportive:
            return "Anvil analysis also leans supportive."
        case .strong:
            return "Anvil analysis reinforces the setup."
        case .unknown:
            return "Anvil analysis is not available."
        }
    }

    private func assessAnvilEvidence(
        raw: TornadoRawParameters,
        rawOverall: IngredientSupport,
        rawConfidence: SnapshotConfidence,
        freshness: IngredientFreshness,
        knownCorePillars: Int,
        evidence: AnvilIngredientEvidence?
    ) -> (overall: IngredientSupport, confidence: SnapshotConfidence) {
        guard let evidence else {
            return (rawOverall, rawConfidence)
        }

        var overall = rawOverall
        var confidence = rawConfidence
        let rawIsAnvilBacked = raw.effectiveLayer != nil || raw.stormMotion != nil

        guard let strongestSupport = evidence.tornadoStrongestSupport else {
            if evidence.isDegraded {
                confidence = confidence.lowered()
            }
            return (overall, confidence)
        }

        if evidence.isDegraded {
            confidence = confidence.lowered()
            return (overall, confidence)
        }

        switch strongestSupport {
        case .strong:
            if !rawIsAnvilBacked {
                if overall == .weak, knownCorePillars >= 3 {
                    overall = overall.raised()
                } else if overall == .conditional, knownCorePillars >= 4 {
                    overall = overall.raised()
                } else if overall == .supportive, knownCorePillars >= 4 {
                    overall = .strong
                }
            }
            if !freshness.isDegraded {
                confidence = confidence.raised()
            }
        case .supportive:
            if !rawIsAnvilBacked {
                if overall == .weak, knownCorePillars >= 3 {
                    overall = overall.raised()
                } else if overall == .conditional, knownCorePillars >= 4 {
                    overall = overall.raised()
                }
            }
            if !freshness.isDegraded {
                confidence = confidence.raised()
            }
        case .conditional:
            if !freshness.isDegraded {
                confidence = confidence.raised()
            }
        case .weak:
            if overall != .weak {
                overall = overall.lowered()
            }
            confidence = confidence.lowered()
        case .unknown:
            break
        }

        return (overall, confidence)
    }
}

struct TornadoViabilityDiagnosis: Sendable {
    let stormViability: IngredientSupport
    let supercellViability: IngredientSupport
    let lowLevelRotation: IngredientSupport
    let lowLevelStretching: IngredientSupport
    let cloudBaseEfficiency: IngredientSupport
    let tornadoEfficiency: IngredientSupport
    let inhibition: IngredientSupport
    let supercellComposite: IngredientSupport
    let compositeConfirmation: IngredientSupport
    let realization: TornadoViabilityRealization
    let failureMode: TornadoViabilityFailureMode
    let confidence: SnapshotConfidence
    let overall: IngredientSupport
    let summary: String
    let primaryDrivers: [String]
    let limitingFactors: [TornadoLimitingFactor]
    let viabilityLimiters: [TornadoViabilityLimiter]
    let instability: IngredientSupport
    let moisture: IngredientSupport
    let cloudBase: IngredientSupport
    let capInhibition: IngredientSupport
    let deepShear: IngredientSupport
    let stormMode: IngredientSupport
    let compositeSignal: IngredientSupport
}

enum TornadoViabilityRealization: Content, Sendable, Hashable {
    case unknown
    case blocked
    case conditional
    case realized
}

enum TornadoViabilityFailureMode: Content, Sendable, Hashable {
    case none
    case weakInstability
    case weakDeepShear
    case weakLowLevelRotation
    case weakLowLevelStretching
    case elevatedCloudBases
    case strongCap
    case conditionalInitiation
    case weakStormOrganization
    case weakLift
    case messyStormMode
    case poorMoisture
    case fixedEffectiveStpDisagreement
    case missingStormMode
    case compositeMismatch
}

private extension TornadoIngredientInterpreter {
    func moistureScore(_ raw: TornadoRawParameters) -> Double? {
        if let mllcl = raw.mllclM {
            return score(idealLow: mllcl, thresholds: [(800, 1.0), (1000, 0.6), (1500, 0.35)], worstScore: 0.0)
        }

        return raw.tempDewPtDeltaF.map { score(idealLow: $0, thresholds: [(8, 1.0), (12, 0.75), (18, 0.45)], worstScore: 0.0) }
    }

    func cloudBaseScore(_ raw: TornadoRawParameters) -> Double? {
        if let mllcl = raw.mllclM {
            return score(idealLow: mllcl, thresholds: [(800, 1.0), (1000, 0.6), (1500, 0.35)], worstScore: 0.0)
        }

        return raw.tempDewPtDeltaF.map { score(idealLow: $0, thresholds: [(8, 1.0), (15, 0.75), (22, 0.45)], worstScore: 0.0) }
    }

    func score(idealLow value: Double, thresholds: [(Double, Double)], worstScore: Double) -> Double {
        for (limit, score) in thresholds {
            if value < limit {
                return score
            }
        }
        return worstScore
    }

    func combineSupport(_ supports: IngredientSupport?...) -> IngredientSupport {
        let known = supports.compactMap { $0 }
        guard !known.isEmpty else {
            return .unknown
        }

        return known.min() ?? .unknown
    }
}
