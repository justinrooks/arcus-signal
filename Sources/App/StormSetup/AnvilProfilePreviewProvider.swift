import Foundation
import Vapor

protocol AnvilProfilePreviewProviding: Sendable {
    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse
}

enum AnvilProfilePreviewError: Error, Sendable, CustomStringConvertible {
    case upstreamUnavailable(reason: String)
    case unusableProfile(reason: String)
    case internalExecutionFailure(reason: String)

    var description: String {
        switch self {
        case .upstreamUnavailable(let reason):
            return "Upstream HRRR data was unavailable. \(reason)"
        case .unusableProfile(let reason):
            return "The grouped HRRR profile could not produce a valid Anvil request. \(reason)"
        case .internalExecutionFailure(let reason):
            return "Anvil preview request assembly failed during internal execution. \(reason)"
        }
    }
}

extension AnvilProfilePreviewError {
    func asAbort() -> Abort {
        switch self {
        case .upstreamUnavailable:
            return Abort(.serviceUnavailable, reason: description)
        case .unusableProfile:
            return Abort(.unprocessableEntity, reason: description)
        case .internalExecutionFailure:
            return Abort(.internalServerError, reason: description)
        }
    }
}

struct DefaultAnvilProfilePreviewProvider: AnvilProfilePreviewProviding {
    private let h3Resolver: any StormSetupH3Resolving
    private let hrrrRunResolver: any HrrrRunResolving
    private let hrrrNomadsURLBuilder: HrrrNomadsURLBuilder
    private let subsetLoader: any StormSetupSubsetLoading
    private let fieldSampler: any StormSetupFieldSampling
    private let pressureGrouper: StormSetupPressureProfileGrouper
    private let requestBuilder: AnvilProfileRequestBuilder

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder = HrrrNomadsURLBuilder(),
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling,
        pressureGrouper: StormSetupPressureProfileGrouper = StormSetupPressureProfileGrouper()
    ) {
        self.h3Resolver = h3Resolver
        self.hrrrRunResolver = hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider)
        self.hrrrNomadsURLBuilder = hrrrNomadsURLBuilder
        self.subsetLoader = subsetLoader
        self.fieldSampler = fieldSampler
        self.pressureGrouper = pressureGrouper
        self.requestBuilder = AnvilProfileRequestBuilder(h3Resolver: h3Resolver)
    }

    init(application: Application) {
        let configuration = application.stormSetupConfiguration
        let dateProvider = SystemStormSetupDateProvider()
        let httpClient = VaporApplicationHTTPClient(application: application)
        let hrrrNomadsURLBuilder = HrrrNomadsURLBuilder()
        let subsetCache = GribSubsetCache(
            httpClient: httpClient,
            rootURL: configuration.gribSubsetCacheRootURL,
            dateProvider: dateProvider,
            retentionDuration: configuration.gribSubsetCacheRetentionSeconds,
            maximumByteCount: configuration.gribSubsetMaximumByteCount
        )
        let subsetLoader = NomadsGribDownloader(
            cache: subsetCache,
            hrrrNomadsURLBuilder: hrrrNomadsURLBuilder
        )
        let fieldSampler = HrrrFieldSampler(client: configuration.makeWgrib2Client())

        self.init(
            dateProvider: dateProvider,
            hrrrNomadsURLBuilder: hrrrNomadsURLBuilder,
            subsetLoader: subsetLoader,
            fieldSampler: fieldSampler
        )
    }

    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let runResolution = hrrrRunResolver.resolveRunCandidates()

        guard !runResolution.candidates.isEmpty else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "No HRRR candidates were available for the preview run."
            )
        }

        var upstreamFailures: [String] = []
        var unusableProfileFailures: [String] = []
        var internalFailures: [String] = []

        for candidate in runResolution.candidates {
            let pressureCandidate = makePressureCandidate(from: candidate)
            let source = hrrrNomadsURLBuilder.makeSourceMetadata(
                for: pressureCandidate,
                around: resolved.centroid
            )

            do {
                let subset = try await subsetLoader.loadFirstAvailableSubset(
                    for: HrrrRunResolution(
                        targetValidTime: runResolution.targetValidTime,
                        candidates: [pressureCandidate]
                    ),
                    around: resolved.centroid
                )

                let samples = try await fieldSampler.sample(from: subset, around: resolved.centroid)
                let groupedProfile = pressureGrouper.group(samples: samples)

                let buildResult = try requestBuilder.build(
                    h3Cell: resolved.h3Cell,
                    runTime: source.runTime ?? pressureCandidate.runTime,
                    forecastHour: source.forecastHour ?? pressureCandidate.forecastHour,
                    groupedProfile: groupedProfile
                )

                let request = buildResult.request
                let debug = AnvilAnalyzeProfilePreviewDebugDTO(
                    product: source.product ?? pressureCandidate.product,
                    runTime: request.runTime,
                    forecastHour: request.forecastHour,
                    validTime: request.validTime,
                    h3: request.location.h3,
                    centroid: StormSetupCentroid(
                        latitude: request.location.lat,
                        longitude: request.location.lon
                    ),
                    pressureLevelsRequested: groupedProfile.requestedLevels.map(\.pressureMb),
                    pressureLevelsRetained: groupedProfile.retainedLevels.map(\.pressureMb),
                    missingLevels: groupedProfile.missingLevels.map {
                        AnvilAnalyzeProfilePreviewMissingLevelDTO(
                            pressureMb: $0.pressureMb,
                            missingVariables: $0.missingVariables
                        )
                    },
                    warnings: makeWarnings(
                        for: buildResult.warnings,
                        ignoredSampleCount: groupedProfile.ignoredSamples.count
                    ),
                    subsetCacheHit: subset.cacheHit
                )

                return AnvilAnalyzeProfilePreviewResponse(request: request, debug: debug)
            } catch let error as GribSubsetCacheError {
                upstreamFailures.append(String(describing: error))
            } catch let error as NomadsGribDownloaderError {
                upstreamFailures.append(String(describing: error))
            } catch let error as AnvilProfileRequestBuilderError {
                unusableProfileFailures.append(classifyBuilderError(error).description)
            } catch let error as Wgrib2ClientError {
                internalFailures.append(classifySamplingError(error).description)
            } catch let error as ProcessRunnerError {
                internalFailures.append(classifySamplingError(error).description)
            } catch let error as AnvilProfilePreviewError {
                switch error {
                case .upstreamUnavailable:
                    upstreamFailures.append(error.description)
                case .unusableProfile:
                    unusableProfileFailures.append(error.description)
                case .internalExecutionFailure:
                    internalFailures.append(error.description)
                }
            } catch {
                internalFailures.append(String(describing: error))
            }
        }

        if !internalFailures.isEmpty {
            throw AnvilProfilePreviewError.internalExecutionFailure(
                reason: internalFailures.joined(separator: "; ")
            )
        }

        if !upstreamFailures.isEmpty {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: upstreamFailures.joined(separator: "; ")
            )
        }

        throw AnvilProfilePreviewError.unusableProfile(
            reason: unusableProfileFailures.joined(separator: "; ")
        )
    }

    private func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
        HrrrRunCandidate(
            model: candidate.model,
            product: .wrfprsf,
            domain: candidate.domain,
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            fieldSetVersion: .tornadoPressureV1
        )
    }

    private func classifySamplingError(_ error: any Error) -> AnvilProfilePreviewError {
        switch error {
        case is Wgrib2ClientError, is ProcessRunnerError:
            return .internalExecutionFailure(reason: String(describing: error))
        default:
            return .internalExecutionFailure(reason: String(describing: error))
        }
    }

    private func classifyBuilderError(_ error: AnvilProfileRequestBuilderError) -> AnvilProfilePreviewError {
        switch error {
        case .noRetainedLevels:
            return .unusableProfile(reason: "No retained pressure levels were available.")
        case .tooFewRetainedLevels(let actual, let minimum):
            return .unusableProfile(
                reason: "Only \(actual) retained levels were available; minimum required is \(minimum)."
            )
        case .unequalArrayLengths(let expected, let actual):
            return .unusableProfile(
                reason: "Pressure arrays had mismatched lengths. Expected \(expected), got \(actual)."
            )
        case .pressureNotStrictlyDescending(let previousPressureMb, let pressureMb):
            return .unusableProfile(
                reason: "Pressure levels were not strictly descending: \(previousPressureMb) then \(pressureMb)."
            )
        }
    }

    private func makeWarnings(
        for warnings: [AnvilProfileRequestWarning],
        ignoredSampleCount: Int
    ) -> [String] {
        var values = warnings.map { warning -> String in
            switch warning {
            case .droppedLevels(let levels):
                let labels = levels
                    .map { "\($0.pressureMb) mb" }
                    .joined(separator: ", ")
                return "Dropped incomplete pressure levels: \(labels)."
            case .nonMonotonicHeight(
                let previousPressureMb,
                let previousHeightMslM,
                let pressureMb,
                let heightMslM
            ):
                return "Non-monotonic height detected between \(previousPressureMb) mb (\(previousHeightMslM)m) and \(pressureMb) mb (\(heightMslM)m)."
            }
        }

        if ignoredSampleCount > 0 {
            values.append("Ignored \(ignoredSampleCount) non-profile HRRR samples while grouping.")
        }

        return values
    }
}

extension Application {
    var anvilProfilePreviewProvider: any AnvilProfilePreviewProviding {
        get {
            storage[AnvilProfilePreviewProviderKey.self] ?? DefaultAnvilProfilePreviewProvider(application: self)
        }
        set {
            storage[AnvilProfilePreviewProviderKey.self] = newValue
        }
    }
}

private struct AnvilProfilePreviewProviderKey: StorageKey {
    typealias Value = any AnvilProfilePreviewProviding
}
