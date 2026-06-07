import Foundation

struct TornadoIngredientNormalizationResult: Sendable {
    let raw: TornadoRawParameters
    let diagnostics: [TornadoRawParameterDiagnostic]
}

struct TornadoIngredientNormalizer: Sendable {
    private let fieldMap: GribInventoryFieldMap

    init(fieldMap: GribInventoryFieldMap = GribInventoryFieldMap()) {
        self.fieldMap = fieldMap
    }

    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult {
        var builder = TornadoRawParametersBuilder()

        for sample in samples {
            let point = sample.point
            let match = fieldMap.match(for: point)
            let diagnostic = TornadoRawParameterDiagnostic(
                inventory: point.inventory,
                parsedValue: point.value,
                matchedRawParameterKey: match?.rawParameterKey,
                requestedLongitude: sample.requestedLongitude,
                requestedLatitude: sample.requestedLatitude,
                nearestLongitude: point.longitude,
                nearestLatitude: point.latitude
            )
            builder.diagnostics.append(diagnostic)

            guard let match, let value = point.value else {
                continue
            }

            builder.record(match: match, value: value)
        }

        return builder.makeResult()
    }
}

private struct TornadoRawParametersBuilder {
    var sbcapeJkg: ParameterCandidate?
    var mlcapeJkg: ParameterCandidate?
    var mucapeJkg: ParameterCandidate?
    var mlcinJkg: ParameterCandidate?
    var mllclM: ParameterCandidate?
    var srh01kmM2s2: ParameterCandidate?
    var srh03kmM2s2: ParameterCandidate?
    var shear06kmU: ParameterCandidate?
    var shear06kmV: ParameterCandidate?
    var diagnostics: [TornadoRawParameterDiagnostic] = []

    mutating func record(match: GribInventoryFieldMatch, value: Double) {
        switch match {
        case .direct(let key, let priority):
            record(key: key, value: value, priority: priority)
        case .vectorComponent(let key, let component, let priority):
            recordVectorComponent(key: key, component: component, value: value, priority: priority)
        }
    }

    mutating func record(key: TornadoRawParameterKey, value: Double, priority: Int) {
        switch key {
        case .sbcapeJkg:
            sbcapeJkg = candidate(existing: sbcapeJkg, value: value, priority: priority)
        case .mlcapeJkg:
            mlcapeJkg = candidate(existing: mlcapeJkg, value: value, priority: priority)
        case .mucapeJkg:
            mucapeJkg = candidate(existing: mucapeJkg, value: value, priority: priority)
        case .mlcinJkg:
            mlcinJkg = candidate(existing: mlcinJkg, value: value, priority: priority)
        case .srh01kmM2s2:
            srh01kmM2s2 = candidate(existing: srh01kmM2s2, value: value, priority: priority)
        case .srh03kmM2s2:
            srh03kmM2s2 = candidate(existing: srh03kmM2s2, value: value, priority: priority)
        case .effectiveSrhM2s2, .effectiveShearKt:
            break
        case .shear06kmKt:
            break
        case .mllclM:
            mllclM = candidate(existing: mllclM, value: value, priority: priority)
        }
    }

    mutating func recordVectorComponent(
        key: TornadoRawParameterKey,
        component: VectorComponent,
        value: Double,
        priority: Int
    ) {
        guard key == .shear06kmKt else {
            return
        }

        switch component {
        case .u:
            shear06kmU = candidate(existing: shear06kmU, value: value, priority: priority)
        case .v:
            shear06kmV = candidate(existing: shear06kmV, value: value, priority: priority)
        }
    }

    func makeResult() -> TornadoIngredientNormalizationResult {
        let shear06kmKt: Double?
        if let shear06kmU, let shear06kmV {
            shear06kmKt = hypot(shear06kmU.value, shear06kmV.value) * Self.metresPerSecondToKnots
        } else {
            shear06kmKt = nil
        }

        return TornadoIngredientNormalizationResult(
            raw: TornadoRawParameters(
                sbcapeJkg: sbcapeJkg?.value,
                mlcapeJkg: mlcapeJkg?.value,
                mucapeJkg: mucapeJkg?.value,
                mlcinJkg: mlcinJkg?.value,
                dcapeJkg: nil,
                mllclM: mllclM?.value,
                temperatureDewpointSpreadF: nil,
                lclLfcSeparationM: nil,
                lapseRate03kmCkm: nil,
                lapseRate700500mbCkm: nil,
                shear06kmKt: shear06kmKt,
                shear03kmKt: nil,
                shear01kmKt: nil,
                effectiveShearKt: nil,
                srh01kmM2s2: srh01kmM2s2?.value,
                srh03kmM2s2: srh03kmM2s2?.value,
                effectiveSrhM2s2: nil,
                supercellComposite: nil,
                significantTornadoFixed: nil,
                significantTornadoEffective: nil,
                significantHail: nil,
                bunkersRightMotion: nil,
                bunkersLeftMotion: nil,
                stormRelativeWind46km: nil,
                meanWind850300mb: nil,
                diagnostics: diagnostics.isEmpty ? nil : diagnostics
            ),
            diagnostics: diagnostics
        )
    }

    private func candidate(existing: ParameterCandidate?, value: Double, priority: Int) -> ParameterCandidate {
        guard let existing else {
            return ParameterCandidate(value: value, priority: priority)
        }

        if priority < existing.priority {
            return ParameterCandidate(value: value, priority: priority)
        }

        return existing
    }

    private static let metresPerSecondToKnots = 1.943_844_492_440_6
}

private struct ParameterCandidate: Sendable, Equatable {
    let value: Double
    let priority: Int
}
