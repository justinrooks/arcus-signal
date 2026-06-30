import Foundation

struct TornadoIngredientNormalizationResult: Sendable {
    let raw: TornadoRawParameters
    let surfaceHeightMslM: Double?
    let diagnostics: [TornadoRawParameterDiagnostic]

    init(
        raw: TornadoRawParameters,
        surfaceHeightMslM: Double? = nil,
        diagnostics: [TornadoRawParameterDiagnostic]
    ) {
        self.raw = raw
        self.surfaceHeightMslM = surfaceHeightMslM
        self.diagnostics = diagnostics
    }
}

struct TornadoIngredientNormalizer: Sendable {
    private let fieldMap: GribInventoryFieldMap

    init(fieldMap: GribInventoryFieldMap = GribInventoryFieldMap()) {
        self.fieldMap = fieldMap
    }

    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult {
        var builder = TornadoRawParametersBuilder()
        let surfaceHeightMslM = surfaceHeightMslM(from: samples)

        for sample in samples {
            let point = sample.point
            if isSurfaceHeightSample(point) {
                continue
            }

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

        return builder.makeResult(surfaceHeightMslM: surfaceHeightMslM)
    }

    private func surfaceHeightMslM(from samples: [HrrrFieldSample]) -> Double? {
        for sample in samples {
            guard isSurfaceHeightSample(sample.point) else { continue }

            return sample.point.value
        }

        return nil
    }

    private func isSurfaceHeightSample(_ point: Wgrib2PointSample) -> Bool {
        guard let descriptor = point.inventoryDescriptor else {
            return false
        }

        return normalizedToken(descriptor.variable) == "HGT"
            && normalizedLevel(descriptor.level) == "surface"
    }

    private func normalizedToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
    }

    private func normalizedLevel(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
    }
}

private struct TornadoRawParametersBuilder {
    var sbcapeJkg: ParameterCandidate?
    var mlcapeJkg: ParameterCandidate?
    var mucapeJkg: ParameterCandidate?
    var mlcinJkg: ParameterCandidate?
    var mllclM: ParameterCandidate?
    var temperature2mK: ParameterCandidate?
    var dewpoint2mK: ParameterCandidate?
    var threeCapeJkg: ParameterCandidate?
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
        case .temperature2mK:
            temperature2mK = candidate(existing: temperature2mK, value: value, priority: priority)
        case .dewpoint2mK:
            dewpoint2mK = candidate(existing: dewpoint2mK, value: value, priority: priority)
        case .tempDewPtDeltaF:
            break
        case .threeCapeJkg:
            threeCapeJkg = candidate(existing: threeCapeJkg, value: value, priority: priority)
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

    func makeResult(surfaceHeightMslM: Double?) -> TornadoIngredientNormalizationResult {
        let shear06kmKt: Double?
        if let shear06kmU, let shear06kmV {
            shear06kmKt = hypot(shear06kmU.value, shear06kmV.value) * Self.metresPerSecondToKnots
        } else {
            shear06kmKt = nil
        }

        let tempDewPtDeltaF: Double?
        if let temperature2mK, let dewpoint2mK {
            // This is a temperature delta, so the Kelvin-to-Celsius offset cancels out.
            // Only the scale factor remains when converting the spread to Fahrenheit.
            tempDewPtDeltaF = (temperature2mK.value - dewpoint2mK.value) * Self.kelvinToFahrenheitDelta
        } else {
            tempDewPtDeltaF = nil
        }

        return TornadoIngredientNormalizationResult(
            raw: TornadoRawParameters(
                sbcapeJkg: sbcapeJkg?.value,
                mlcapeJkg: mlcapeJkg?.value,
                mucapeJkg: mucapeJkg?.value,
                mlcinJkg: mlcinJkg?.value,
                dcapeJkg: nil,
                mllclM: mllclM?.value,
                tempDewPtDeltaF: tempDewPtDeltaF,
                threeCapeJkg: threeCapeJkg?.value,
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
            surfaceHeightMslM: surfaceHeightMslM,
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
    private static let kelvinToFahrenheitDelta = 1.8
}

private struct ParameterCandidate: Sendable, Equatable {
    let value: Double
    let priority: Int
}
