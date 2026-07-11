import Foundation
import ArcusCore

protocol HrrrAnvilSurfaceProfileLoading: Sendable {
    func loadSurfaceProfile(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> HrrrAnvilSurfaceProfileLoadResult
}

struct HrrrAnvilSurfaceProfileLoadResult: Sendable {
    let sourceResolution: HrrrRunResolution
    let subsetCacheResult: GribSubsetCacheResult
    let surfaceLevel: StormSetupSurfaceProfileLevel
}

enum HrrrAnvilSurfaceProfileLoadingError: Error, Sendable, CustomStringConvertible {
    case noSurfaceCandidate

    var description: String {
        switch self {
        case .noSurfaceCandidate:
            return "No HRRR surface candidate was available."
        }
    }
}

struct DefaultHrrrAnvilSurfaceProfileLoader: HrrrAnvilSurfaceProfileLoading {
    private let subsetLoader: any StormSetupSubsetLoading
    private let fieldSampler: any StormSetupFieldSampling

    init(
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling
    ) {
        self.subsetLoader = subsetLoader
        self.fieldSampler = fieldSampler
    }

    func loadSurfaceProfile(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> HrrrAnvilSurfaceProfileLoadResult {
        let surfaceResolution = try makeSurfaceResolution(from: resolution)

        let subset = try await loadSubset(
            for: surfaceResolution,
            around: centroid
        )
        try Task.checkCancellation()

        let samples = try await loadSamples(
            from: subset,
            around: centroid
        )
        try Task.checkCancellation()
        let surfaceLevel = try AnvilSurfaceProfileNormalizer().normalize(samples: samples)

        return HrrrAnvilSurfaceProfileLoadResult(
            sourceResolution: surfaceResolution,
            subsetCacheResult: subset,
            surfaceLevel: surfaceLevel
        )
    }

    private func makeSurfaceResolution(
        from resolution: HrrrRunResolution
    ) throws -> HrrrRunResolution {
        guard let primaryCandidate = resolution.primaryCandidate else {
            throw HrrrAnvilSurfaceProfileLoadingError.noSurfaceCandidate
        }

        let surfaceCandidate = HrrrRunCandidate(
            model: primaryCandidate.model,
            product: .wrfsfc,
            domain: primaryCandidate.domain,
            runTime: primaryCandidate.runTime,
            forecastHour: primaryCandidate.forecastHour,
            fieldSetVersion: .anvilSurfaceV1
        )

        return HrrrRunResolution(
            targetValidTime: resolution.targetValidTime,
            candidates: [surfaceCandidate]
        )
    }

    private func loadSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        do {
            return try await subsetLoader.loadFirstAvailableSubset(
                for: resolution,
                around: centroid
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw error
        }
    }

    private func loadSamples(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample] {
        do {
            return try await fieldSampler.sample(
                from: subset,
                around: centroid
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw error
        }
    }
}
