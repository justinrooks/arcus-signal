import Foundation

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
            lowLevelRotation: diagnosis.lowLevelRotation,
            stormMode: diagnosis.stormMode,
            compositeSignal: diagnosis.compositeSignal,
            confidence: diagnosis.confidence,
            trend: .unknown,
            stormModeHint: .unknown,
            primaryDrivers: diagnosis.primaryDrivers,
            limitingFactors: diagnosis.limitingFactors,
            summary: diagnosis.summary
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
        let lowLevelStretching = raw.threeCapeJkg.map(assessThreeCape)
        let cloudBaseEfficiency = cloudBaseSupport(raw)
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
            lowLevelRotation,
            cloudBase,
            supercellSupport
        ].filter { $0 != .unknown }.count

        let limitingFactors = makeLimitingFactors(
            raw: raw,
            instability: instability,
            moisture: moisture,
            cloudBase: cloudBase,
            capInhibition: capInhibition,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
            stormMode: stormMode,
            compositeSignal: tornadoComposite
        )

        let baselineOverall = assessOverall(
            instability: instability,
            cloudBase: cloudBase,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
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

        return TornadoViabilityDiagnosis(
            stormViability: stormViability,
            supercellViability: supercellViability,
            lowLevelRotation: lowLevelRotation,
            lowLevelStretching: lowLevelStretching ?? .unknown,
            cloudBaseEfficiency: cloudBaseEfficiency ?? .unknown,
            tornadoEfficiency: tornadoEfficiency,
            inhibition: capInhibition,
            compositeConfirmation: compositeConfirmation,
            realization: assessRealization(
                overall: evidenceAdjusted.overall,
                tornadoEfficiency: tornadoEfficiency,
                inhibition: capInhibition
            ),
            failureMode: assessFailureMode(
                limitingFactors: limitingFactors,
                supercellSupport: supercellSupport,
                tornadoComposite: tornadoComposite,
                compositeConfirmation: compositeConfirmation
            ),
            confidence: evidenceAdjusted.confidence,
            overall: evidenceAdjusted.overall,
            summary: makeSummary(
                overall: evidenceAdjusted.overall,
                raw: raw,
                limitingFactors: limitingFactors,
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
                lowLevelRotation: lowLevelRotation,
                supercellSupport: supercellSupport,
                compositeSignal: tornadoComposite
            ),
            limitingFactors: limitingFactors,
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
        let rotationSupport: IngredientSupport?

        if let srh01kmM2s2 = raw.srh01kmM2s2 {
            rotationSupport = assessSRH01km(srh01kmM2s2)
        } else if let effectiveSrh = raw.effectiveSrhM2s2 {
            rotationSupport = assessEffectiveSRH(effectiveSrh)
        } else if let srh03kmM2s2 = raw.srh03kmM2s2 {
            rotationSupport = assessSRH03km(srh03kmM2s2)
        } else {
            rotationSupport = nil
        }

        let stretchingSupport = raw.threeCapeJkg.map(assessThreeCape)
        let cloudBaseTier = cloudBaseSupport(raw)
        let supports = [rotationSupport, stretchingSupport].compactMap { $0 }
        guard !supports.isEmpty else {
            return .unknown
        }

        var combined = supports.min() ?? .unknown
        if let cloudBaseTier {
            combined = min(combined, cloudBaseTier)
        }

        return combined
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
        inhibition: IngredientSupport
    ) -> TornadoViabilityRealization {
        switch overall {
        case .unknown:
            return .unknown
        case .weak:
            return .blocked
        case .conditional:
            if inhibition <= .conditional {
                return .blocked
            }

            return tornadoEfficiency >= .supportive ? .conditional : .blocked
        case .supportive:
            return inhibition <= .conditional ? .blocked : .conditional
        case .strong:
            return .realized
        }
    }

    private func assessFailureMode(
        limitingFactors: [TornadoLimitingFactor],
        supercellSupport: IngredientSupport,
        tornadoComposite: IngredientSupport,
        compositeConfirmation: IngredientSupport
    ) -> TornadoViabilityFailureMode {
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
        if limitingFactors.contains(.strongCap) {
            return .strongCap
        }
        if limitingFactors.contains(.weakLift) {
            return .weakLift
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
        supercellSupport: IngredientSupport,
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
        if cloudBase >= .supportive {
            drivers.append("Cloud bases are favorable.")
        }
        if supercellSupport >= .supportive {
            drivers.append("Supercell organization is supportive.")
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
            baseSummary = "The setup is weakly supportive. Key ingredients are limited and the environment is not especially favorable."
        case .conditional:
            if let fixed = raw.significantTornadoFixed,
               let effective = raw.significantTornadoEffective,
               fixed >= 1.5,
               effective + 0.5 < fixed {
                baseSummary = "The setup is conditionally supportive. The fixed-layer tornado signal is stronger than the effective-layer signal, so realization stays conditional if storms initiate."
            } else if supercellSupport >= .supportive, compositeSignal <= .conditional {
                baseSummary = "The setup is conditionally supportive. Supercell support is present, but tornado-specific composite support is limited."
            } else if capInhibition <= .conditional {
                baseSummary = "The setup is conditionally supportive. The ingredients are there, but storm initiation and CIN may keep the tornado potential from fully realizing."
            } else if lowLevelRotation <= .conditional, compositeSignal >= .supportive {
                baseSummary = "The setup is conditionally supportive. Supercell ingredients are present, but low-level rotation and stretching are still the limiter."
            } else if lowLevelRotation >= .supportive, cloudBase >= .conditional {
                baseSummary = "The setup is conditionally supportive. The low-level tornado ingredients are more aligned, but the outcome still depends on storm initiation."
            } else if compositeSignal == .unknown {
                baseSummary = "The setup is conditionally supportive. Instability and deep shear are present, but the composite signal is not available yet."
            } else {
                baseSummary = "The setup is conditionally supportive. The ingredients are there, but the lineup is still incomplete."
            }
        case .supportive:
            baseSummary = "The setup is supportive. Instability, deep shear, and low-level tornado ingredients are in a favorable range."
        case .strong:
            baseSummary = "The setup is strongly supportive. Multiple ingredients line up, including instability, deep shear, and low-level tornado ingredients."
        case .unknown:
            baseSummary = "There is not enough ingredient data to judge the setup confidently."
        }

        guard let anvilEvidence else {
            return baseSummary
        }

        return baseSummary + " " + makeAnvilEvidenceSummaryClause(anvilEvidence)
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
    let compositeConfirmation: IngredientSupport
    let realization: TornadoViabilityRealization
    let failureMode: TornadoViabilityFailureMode
    let confidence: SnapshotConfidence
    let overall: IngredientSupport
    let summary: String
    let primaryDrivers: [String]
    let limitingFactors: [TornadoLimitingFactor]
    let instability: IngredientSupport
    let moisture: IngredientSupport
    let cloudBase: IngredientSupport
    let capInhibition: IngredientSupport
    let deepShear: IngredientSupport
    let stormMode: IngredientSupport
    let compositeSignal: IngredientSupport
}

enum TornadoViabilityRealization: Sendable {
    case unknown
    case blocked
    case conditional
    case realized
}

enum TornadoViabilityFailureMode: Sendable {
    case none
    case weakInstability
    case weakDeepShear
    case weakLowLevelRotation
    case elevatedCloudBases
    case strongCap
    case weakLift
    case messyStormMode
    case poorMoisture
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
