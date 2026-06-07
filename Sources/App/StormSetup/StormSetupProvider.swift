import Foundation
import Vapor

protocol StormSetupProviding: Sendable {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot
}

struct DefaultStormSetupProvider: StormSetupProviding {
    private let h3Resolver: any StormSetupH3Resolving

    init(h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver()) {
        self.h3Resolver = h3Resolver
    }

    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let fetchedAt = Date()

        return TornadoIngredientSnapshot(
            h3Cell: resolved.h3Cell,
            centroid: resolved.centroid,
            source: StormSetupSourceMetadata(
                model: nil,
                runTime: nil,
                forecastHour: nil,
                validTime: nil
            ),
            raw: TornadoRawParameters(
                sbcapeJkg: nil,
                mlcapeJkg: nil,
                mucapeJkg: nil,
                dcapeJkg: nil,
                mllclM: nil,
                temperatureDewpointSpreadF: nil,
                lclLfcSeparationM: nil,
                lapseRate03kmCkm: nil,
                lapseRate700500mbCkm: nil,
                shear06kmKt: nil,
                shear03kmKt: nil,
                shear01kmKt: nil,
                effectiveShearKt: nil,
                srh01kmM2s2: nil,
                srh03kmM2s2: nil,
                effectiveSrhM2s2: nil,
                supercellComposite: nil,
                significantTornadoFixed: nil,
                significantTornadoEffective: nil,
                significantHail: nil,
                bunkersRightMotion: nil,
                bunkersLeftMotion: nil,
                stormRelativeWind46km: nil,
                meanWind850300mb: nil
            ),
            assessment: TornadoIngredientAssessment(
                overall: nil,
                instability: nil,
                moisture: nil,
                cloudBase: nil,
                capInhibition: nil,
                deepShear: nil,
                lowLevelRotation: nil,
                stormMode: nil,
                compositeSignal: nil,
                confidence: nil,
                trend: nil,
                stormModeHint: nil,
                primaryDrivers: nil,
                limitingFactors: nil,
                summary: nil
            ),
            freshness: IngredientFreshness(
                sourceValidTime: nil,
                modelRunTime: nil,
                forecastHour: nil,
                fetchedAt: fetchedAt,
                expiresAt: nil,
                isStale: true
            )
        )
    }
}

private struct StormSetupProviderKey: StorageKey {
    typealias Value = any StormSetupProviding
}

extension Application {
    var stormSetupProvider: any StormSetupProviding {
        get {
            storage[StormSetupProviderKey.self] ?? DefaultStormSetupProvider()
        }
        set {
            storage[StormSetupProviderKey.self] = newValue
        }
    }
}
