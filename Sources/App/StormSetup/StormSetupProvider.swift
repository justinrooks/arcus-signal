import Foundation
import Vapor

protocol StormSetupProviding: Sendable {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot
}

struct DefaultStormSetupProvider: StormSetupProviding {
    private let h3Resolver: any StormSetupH3Resolving
    private let dateProvider: any StormSetupDateProviding
    private let hrrrRunResolver: any HrrrRunResolving
    private let hrrrNomadsURLBuilder: HrrrNomadsURLBuilder

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder = HrrrNomadsURLBuilder()
    ) {
        self.h3Resolver = h3Resolver
        self.dateProvider = dateProvider
        self.hrrrRunResolver = hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider)
        self.hrrrNomadsURLBuilder = hrrrNomadsURLBuilder
    }

    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let fetchedAt = dateProvider.now()
        let runResolution = hrrrRunResolver.resolveRunCandidates()
        let sourceMetadata: StormSetupSourceMetadata
        let freshness: IngredientFreshness
        let assessment: TornadoIngredientAssessment
        let raw = TornadoRawParameters.empty

        if let candidate = runResolution.primaryCandidate {
            sourceMetadata = hrrrNomadsURLBuilder.makeSourceMetadata(
                for: candidate,
                around: resolved.centroid
            )
            freshness = IngredientFreshness.make(source: sourceMetadata, fetchedAt: fetchedAt)
        } else {
            sourceMetadata = StormSetupSourceMetadata(
                model: nil,
                product: nil,
                domain: nil,
                runTime: nil,
                forecastHour: nil,
                validTime: nil,
                fieldSetVersion: nil,
                bbox: nil,
                nomadsURL: nil
            )
            freshness = IngredientFreshness.make(source: sourceMetadata, fetchedAt: fetchedAt)
        }

        assessment = TornadoIngredientInterpreter().assess(raw: raw, freshness: freshness)

        return TornadoIngredientSnapshot(
            h3Cell: resolved.h3Cell,
            centroid: resolved.centroid,
            source: sourceMetadata,
            raw: raw,
            assessment: assessment,
            freshness: freshness
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
