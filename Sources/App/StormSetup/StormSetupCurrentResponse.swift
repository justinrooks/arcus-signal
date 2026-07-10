import Foundation
import ArcusCore

extension TornadoViabilityReport {
    init(diagnosis: TornadoViabilityDiagnosis) {
        self.init(
            overall: diagnosis.overall,
            realization: diagnosis.realization,
            primaryFailureMode: diagnosis.failureMode,
            confidence: diagnosis.confidence,
            summary: diagnosis.summary,
            details: TornadoViabilityDetails(
                stormViability: diagnosis.stormViability,
                supercellViability: diagnosis.supercellViability,
                tornadoEfficiency: diagnosis.tornadoEfficiency,
                inhibition: diagnosis.inhibition,
                instability: diagnosis.instability,
                moisture: diagnosis.moisture,
                cloudBase: diagnosis.cloudBase,
                deepShear: diagnosis.deepShear,
                lowLevelRotation: diagnosis.lowLevelRotation,
                lowLevelStretching: diagnosis.lowLevelStretching,
                cloudBaseEfficiency: diagnosis.cloudBaseEfficiency,
                supercellComposite: diagnosis.supercellComposite,
                tornadoComposite: diagnosis.compositeSignal,
                stormMode: diagnosis.stormMode,
            ),
            limitingFactors: diagnosis.viabilityLimiters
        )
    }

    init(assessment: TornadoIngredientAssessment) {
        let limitingFactors = assessment.viabilityLimiters ?? Self.mapLegacyLimiters(assessment.limitingFactors)
        self.init(
            overall: assessment.overall,
            realization: assessment.realization ?? .unknown,
            primaryFailureMode: assessment.primaryFailureMode ?? Self.mapFailureMode(from: limitingFactors),
            confidence: assessment.confidence,
            summary: assessment.summary,
            details: TornadoViabilityDetails(
                stormViability: assessment.stormViability ?? .unknown,
                supercellViability: assessment.supercellViability ?? .unknown,
                tornadoEfficiency: assessment.tornadoEfficiency ?? assessment.lowLevelRotation,
                inhibition: assessment.capInhibition,
                instability: assessment.instability,
                moisture: assessment.moisture,
                cloudBase: assessment.cloudBase,
                deepShear: assessment.deepShear,
                lowLevelRotation: assessment.lowLevelRotationSupport ?? assessment.lowLevelRotation,
                lowLevelStretching: assessment.lowLevelStretching ?? .unknown,
                cloudBaseEfficiency: assessment.cloudBaseEfficiency ?? .unknown,
                supercellComposite: assessment.supercellComposite ?? assessment.compositeSignal,
                tornadoComposite: assessment.compositeSignal,
                stormMode: assessment.stormMode
            ),
            limitingFactors: limitingFactors
        )
    }

    private static func mapFailureMode(from limitingFactors: [TornadoViabilityLimiter]) -> TornadoViabilityFailureMode {
        if limitingFactors.contains(.strongCap) {
            return .strongCap
        }
        if limitingFactors.contains(.conditionalInitiation) {
            return .conditionalInitiation
        }
        if limitingFactors.contains(.fixedEffectiveStpDisagreement) {
            return .fixedEffectiveStpDisagreement
        }
        if limitingFactors.contains(.weakStormOrganization) {
            return .weakStormOrganization
        }
        if limitingFactors.contains(.weakLowLevelStretching) {
            return .weakLowLevelStretching
        }
        if limitingFactors.contains(.weakLowLevelRotation) {
            return .weakLowLevelRotation
        }
        if limitingFactors.contains(.elevatedCloudBases) {
            return .elevatedCloudBases
        }
        if limitingFactors.contains(.weakDeepShear) {
            return .weakDeepShear
        }
        if limitingFactors.contains(.weakInstability) {
            return .weakInstability
        }
        if limitingFactors.contains(.poorMoisture) {
            return .poorMoisture
        }
        if limitingFactors.contains(.missingStormMode) {
            return .missingStormMode
        }

        return .none
    }

    private static func mapLegacyLimiters(_ legacy: [TornadoLimitingFactor]) -> [TornadoViabilityLimiter] {
        legacy.map { factor in
            switch factor {
            case .weakInstability:
                return .weakInstability
            case .weakDeepShear:
                return .weakDeepShear
            case .weakLowLevelRotation:
                return .weakLowLevelRotation
            case .elevatedCloudBases:
                return .elevatedCloudBases
            case .strongCap:
                return .strongCap
            case .weakLift:
                return .conditionalInitiation
            case .messyStormMode:
                return .weakStormOrganization
            case .poorMoisture:
                return .poorMoisture
            case .unknown:
                return .unknown
            }
        }
    }
}
