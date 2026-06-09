import Foundation

struct NomadsGribCandidateFailure: Sendable {
    let source: StormSetupSourceMetadata
    let errorDescription: String
}

enum NomadsGribDownloaderError: Error, Sendable, CustomStringConvertible {
    case noCandidatesProvided
    case allCandidatesFailed([NomadsGribCandidateFailure])

    var description: String {
        switch self {
        case .noCandidatesProvided:
            return "No HRRR candidates were provided for NOMADS download."
        case .allCandidatesFailed(let failures):
            let summaries = failures.map { failure in
                "\(failure.source): \(failure.errorDescription)"
            }
            .joined(separator: "; ")
            return "All HRRR NOMADS candidates failed: \(summaries)"
        }
    }
}

struct NomadsGribDownloader: Sendable {
    private let cache: GribSubsetCache
    private let hrrrNomadsURLBuilder: HrrrNomadsURLBuilder

    init(
        cache: GribSubsetCache,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder = HrrrNomadsURLBuilder()
    ) {
        self.cache = cache
        self.hrrrNomadsURLBuilder = hrrrNomadsURLBuilder
    }

    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        guard !resolution.candidates.isEmpty else {
            throw NomadsGribDownloaderError.noCandidatesProvided
        }

        var failures: [NomadsGribCandidateFailure] = []

        for candidate in resolution.candidates {
            let sourceMetadata = hrrrNomadsURLBuilder.makeSourceMetadata(
                for: candidate,
                around: centroid
            )

            do {
                return try await cache.loadOrFetch(sourceMetadata: sourceMetadata)
            } catch {
                failures.append(
                    NomadsGribCandidateFailure(
                        source: sourceMetadata,
                        errorDescription: String(describing: error)
                    )
                )
            }
        }

        throw NomadsGribDownloaderError.allCandidatesFailed(failures)
    }
}
