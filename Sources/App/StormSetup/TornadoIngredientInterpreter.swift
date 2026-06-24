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
        let instability = assessInstability(raw)
        let moisture = assessMoisture(raw)
        let cloudBase = assessCloudBase(raw)
        let capInhibition = assessCapInhibition(raw)
        let deepShear = assessDeepShear(raw)
        let lowLevelRotation = assessLowLevelRotation(raw)
        let compositeSignal = assessCompositeSignal(raw)
        let stormMode = assessStormMode()

        let knownCorePillars = [
            instability,
            deepShear,
            lowLevelRotation,
            cloudBase,
            compositeSignal
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
            compositeSignal: compositeSignal
        )

        let baselineOverall = assessOverall(
            instability: instability,
            cloudBase: cloudBase,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
            compositeSignal: compositeSignal,
            knownCorePillars: knownCorePillars
        )

        let baselineConfidence = assessConfidence(freshness: freshness, knownCorePillars: knownCorePillars)
        let evidenceAdjusted = assessAnvilEvidence(
            rawOverall: baselineOverall,
            rawConfidence: baselineConfidence,
            freshness: freshness,
            knownCorePillars: knownCorePillars,
            evidence: anvilEvidence
        )

        return TornadoIngredientAssessment(
            overall: evidenceAdjusted.overall,
            instability: instability,
            moisture: moisture,
            cloudBase: cloudBase,
            capInhibition: capInhibition,
            deepShear: deepShear,
            lowLevelRotation: lowLevelRotation,
            stormMode: stormMode,
            compositeSignal: compositeSignal,
            confidence: evidenceAdjusted.confidence,
            trend: .unknown,
            stormModeHint: .unknown,
            primaryDrivers: makePrimaryDrivers(
                instability: instability,
                moisture: moisture,
                cloudBase: cloudBase,
                capInhibition: capInhibition,
                deepShear: deepShear,
                lowLevelRotation: lowLevelRotation,
                compositeSignal: compositeSignal
            ),
            limitingFactors: limitingFactors,
            summary: makeSummary(
                overall: evidenceAdjusted.overall,
                limitingFactors: limitingFactors,
                compositeSignal: compositeSignal,
                anvilEvidence: anvilEvidence
            )
        )
    }

    private func assessInstability(_ raw: TornadoRawParameters) -> IngredientSupport {
        let values = [raw.mlcapeJkg, raw.mucapeJkg, raw.sbcapeJkg].compactMap { $0 }
        guard let strongest = values.max() else {
            return .unknown
        }

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
        case ..<(-100):
            return .weak
        case ..<(-75):
            return .conditional
        case ..<(-25):
            return .strong
        default:
            return .conditional
        }
    }

    private func assessDeepShear(_ raw: TornadoRawParameters) -> IngredientSupport {
        let values = [raw.effectiveShearKt, raw.shear06kmKt].compactMap { $0 }
        guard let strongest = values.max() else {
            return .unknown
        }

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
        let supports = [
            raw.effectiveSrhM2s2.map(assessEffectiveSRH),
            raw.srh03kmM2s2.map(assessSRH03km),
            raw.srh01kmM2s2.map(assessSRH01km)
        ].compactMap { $0 }
        guard let strongest = supports.max() else {
            return .unknown
        }

        return strongest
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
        assessSRH01km(value)
    }

    private func assessStormMode() -> IngredientSupport {
        let _ = rulesVersion
        return .unknown
    }

    private func assessCompositeSignal(_ raw: TornadoRawParameters) -> IngredientSupport {
        let values = [
            raw.supercellComposite,
            raw.significantTornadoFixed,
            raw.significantTornadoEffective
        ].compactMap { $0 }
        guard let strongest = values.max() else {
            return .unknown
        }

        switch strongest {
        case ..<1:
            return .weak
        case ..<2:
            return .conditional
        case ..<4:
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
        compositeSignal: IngredientSupport,
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
            compositeSignal
        ].filter { $0 == .strong }.count

        if instability >= .supportive,
           deepShear >= .supportive,
           lowLevelRotation >= .supportive,
           cloudBase >= .supportive,
           compositeSignal >= .supportive,
           strongAgreementCount >= 3 {
            return .strong
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
            drivers.append("Low-level rotation is supportive.")
        }
        if cloudBase >= .supportive {
            drivers.append("Cloud bases are favorable.")
        }
        if compositeSignal >= .supportive {
            drivers.append("Composite signals are supportive.")
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
        if let cin = raw.mlcinJkg, cin <= -100 {
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
        limitingFactors: [TornadoLimitingFactor],
        compositeSignal: IngredientSupport,
        anvilEvidence: AnvilIngredientEvidence?
    ) -> String {
        let baseSummary: String

        switch overall {
        case .weak:
            baseSummary = "The setup is weakly supportive. Key ingredients are limited and the environment is not especially favorable."
        case .conditional:
            if limitingFactors.contains(.weakLowLevelRotation) {
                baseSummary = "The setup is conditionally supportive. Instability and deep shear are present, but low-level rotation is modest."
            } else if compositeSignal == .unknown {
                baseSummary = "The setup is conditionally supportive. Instability and deep shear are present, but the composite signal is not available yet."
            } else {
                baseSummary = "The setup is conditionally supportive. The ingredients are there, but the lineup is still incomplete."
            }
        case .supportive:
            baseSummary = "The setup is supportive. Instability, deep shear, and cloud bases are in a favorable range."
        case .strong:
            baseSummary = "The setup is strongly supportive. Multiple ingredients line up, including instability, deep shear, and low-level rotation."
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

        guard let strongestSupport = evidence.strongestSupport else {
            return "Anvil analysis is not available."
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

        guard let strongestSupport = evidence.strongestSupport else {
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
            if overall == .weak, knownCorePillars >= 3 {
                overall = overall.raised()
            } else if overall == .conditional, knownCorePillars >= 4 {
                overall = overall.raised()
            } else if overall == .supportive, knownCorePillars >= 4 {
                overall = .strong
            }
            if !freshness.isDegraded {
                confidence = confidence.raised()
            }
        case .supportive:
            if overall == .weak, knownCorePillars >= 3 {
                overall = overall.raised()
            } else if overall == .conditional, knownCorePillars >= 4 {
                overall = overall.raised()
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

private extension TornadoIngredientInterpreter {
    func moistureScore(_ raw: TornadoRawParameters) -> Double? {
        let scores: [Double] = [
            raw.mllclM.map { score(idealLow: $0, thresholds: [(800, 1.0), (1000, 0.6), (1500, 0.35)], worstScore: 0.0) },
            raw.temperatureDewpointSpreadF.map { score(idealLow: $0, thresholds: [(8, 1.0), (12, 0.75), (18, 0.45)], worstScore: 0.0) }
        ].compactMap { $0 }

        guard !scores.isEmpty else {
            return nil
        }

        return scores.reduce(0, +) / Double(scores.count)
    }

    func cloudBaseScore(_ raw: TornadoRawParameters) -> Double? {
        let scores: [Double] = [
            raw.mllclM.map { score(idealLow: $0, thresholds: [(800, 1.0), (1000, 0.6), (1500, 0.35)], worstScore: 0.0) },
            raw.temperatureDewpointSpreadF.map { score(idealLow: $0, thresholds: [(8, 1.0), (15, 0.75), (22, 0.45)], worstScore: 0.0) }
        ].compactMap { $0 }

        guard !scores.isEmpty else {
            return nil
        }

        return scores.reduce(0, +) / Double(scores.count)
    }

    func score(idealLow value: Double, thresholds: [(Double, Double)], worstScore: Double) -> Double {
        for (limit, score) in thresholds {
            if value < limit {
                return score
            }
        }
        return worstScore
    }
}
