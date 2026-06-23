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
    private let pressureSourceResolver: any HrrrPressureDirectObjectResolving
    private let pressureProfileLoader: any HrrrPressureProfileLoading
    private let requestBuilder: AnvilProfileRequestBuilder

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        pressureSourceResolver: any HrrrPressureDirectObjectResolving,
        pressureProfileLoader: any HrrrPressureProfileLoading
    ) {
        self.h3Resolver = h3Resolver
        self.hrrrRunResolver = hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider)
        self.pressureSourceResolver = pressureSourceResolver
        self.pressureProfileLoader = pressureProfileLoader
        self.requestBuilder = AnvilProfileRequestBuilder(h3Resolver: h3Resolver)
    }

    init(application: Application) {
        let configuration = application.stormSetupConfiguration
        let dateProvider = SystemStormSetupDateProvider()
        let httpClient = VaporApplicationHTTPClient(application: application)
        let pressureSourceResolver = DefaultHrrrPressureDirectObjectResolver(httpClient: httpClient)
        let pressureProfileLoader = DefaultHrrrPressureProfileLoader(
            httpClient: httpClient,
            subsetCache: HrrrPressureSubsetGribCache(
                httpClient: httpClient,
                rootURL: configuration.pressureGribSubsetCacheRootURL,
                dateProvider: dateProvider,
                retentionDuration: configuration.gribSubsetCacheRetentionSeconds,
                maximumByteCount: configuration.gribSubsetMaximumByteCount
            ),
            fieldSampler: HrrrFieldSampler(client: configuration.makeWgrib2Client())
        )

        self.init(
            dateProvider: dateProvider,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
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
            do {
                let preview = try await previewPressureCandidate(
                    pressureCandidate,
                    h3Cell: resolved.h3Cell,
                    centroid: resolved.centroid,
                    targetValidTime: runResolution.targetValidTime
                )
                return preview
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

    private func previewPressureCandidate(
        _ candidate: HrrrRunCandidate,
        h3Cell: Int64,
        centroid: StormSetupCentroid,
        targetValidTime: Date
    ) async throws -> AnvilAnalyzeProfilePreviewResponse {
        let sourceResolution = try await resolvePressureSource(
            for: candidate,
            targetValidTime: targetValidTime
        )
        let loadResult = try await loadPressureProfile(
            sourceResolution: sourceResolution,
            centroid: centroid
        )

        let buildResult: AnvilProfileRequestBuildResult
        do {
            buildResult = try requestBuilder.build(
                h3Cell: h3Cell,
                runTime: sourceResolution.source.runTime ?? candidate.runTime,
                forecastHour: sourceResolution.source.forecastHour ?? candidate.forecastHour,
                groupedProfile: loadResult.groupedProfile
            )
        } catch let error as AnvilProfileRequestBuilderError {
            throw classifyBuilderError(error, missingLevels: loadResult.groupedProfile.missingLevels)
        } catch {
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
        }

        let request = buildResult.request
        let debug = AnvilAnalyzeProfilePreviewDebugDTO(
            sourceKind: sourceResolution.source.sourceKind,
            product: sourceResolution.source.product ?? candidate.product,
            runTime: request.runTime,
            forecastHour: request.forecastHour,
            validTime: request.validTime,
            h3: request.location.h3,
            centroid: StormSetupCentroid(
                latitude: request.location.lat,
                longitude: request.location.lon
            ),
            selectedMessageCount: loadResult.selection.selectedMessages.count,
            selectedPressureLevels: uniquePressureLevels(from: loadResult.selection),
            rangeCount: loadResult.byteRangePlan.ranges.count,
            totalSelectedRangeBytes: loadResult.subsetCacheResult.byteSize,
            pressureLevelsRequested: loadResult.groupedProfile.requestedLevels.map(\.pressureMb),
            pressureLevelsRetained: loadResult.groupedProfile.retainedLevels.map(\.pressureMb),
            missingLevels: loadResult.groupedProfile.missingLevels.map {
                AnvilAnalyzeProfilePreviewMissingLevelDTO(
                    pressureMb: $0.pressureMb,
                    missingVariables: $0.missingVariables
                )
            },
            warnings: makeWarnings(
                for: buildResult.warnings,
                ignoredSampleCount: loadResult.groupedProfile.ignoredSamples.count
            ),
            subsetCacheHit: loadResult.subsetCacheResult.cacheHit,
            primaryDownloadURL: sourceResolution.source.primaryDownloadURL,
            idxURL: sourceResolution.source.idxURL,
            idxAvailable: sourceResolution.idxProbe.available,
            gribAvailable: sourceResolution.gribProbe?.available
        )

        return AnvilAnalyzeProfilePreviewResponse(request: request, debug: debug)
    }

    private func resolvePressureSource(
        for candidate: HrrrRunCandidate,
        targetValidTime: Date
    ) async throws -> HrrrPressureDirectObjectResolution {
        do {
            return try await pressureSourceResolver.resolveSource(
                for: HrrrRunResolution(
                    targetValidTime: targetValidTime,
                    candidates: [candidate]
                )
            )
        } catch let error as HrrrPressureDirectObjectResolverError {
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        } catch {
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }
    }

    private func loadPressureProfile(
        sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid
    ) async throws -> HrrrPressureProfileLoadResult {
        do {
            return try await pressureProfileLoader.loadPressureProfile(
                for: sourceResolution,
                centroid: centroid
            )
        } catch let error as AnvilProfilePreviewError {
            throw error
        } catch {
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }
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

    private func classifyBuilderError(
        _ error: AnvilProfileRequestBuilderError,
        missingLevels: [StormSetupPressureProfileMissingLevel]
    ) -> AnvilProfilePreviewError {
        let missingSummary = makeMissingLevelsSummary(missingLevels)

        switch error {
        case .noRetainedLevels:
            return .unusableProfile(
                reason: "No retained pressure levels were available. \(missingSummary)"
            )
        case .tooFewRetainedLevels(let actual, let minimum):
            return .unusableProfile(
                reason: "Only \(actual) retained levels were available; minimum required is \(minimum). \(missingSummary)"
            )
        case .unequalArrayLengths(let expected, let actual):
            return .unusableProfile(
                reason: "Pressure arrays had mismatched lengths. Expected \(expected), got \(actual). \(missingSummary)"
            )
        case .pressureNotStrictlyDescending(let previousPressureMb, let pressureMb):
            return .unusableProfile(
                reason: "Pressure levels were not strictly descending: \(previousPressureMb) then \(pressureMb). \(missingSummary)"
            )
        }
    }

    private func makeMissingLevelsSummary(_ levels: [StormSetupPressureProfileMissingLevel]) -> String {
        guard !levels.isEmpty else {
            return "Missing or incomplete levels were not reported."
        }

        let labels = levels.map { level in
            "\(level.pressureMb) mb missing \(level.missingVariables.map(\.rawValue).joined(separator: ", "))"
        }
        .joined(separator: "; ")

        return "Missing or incomplete levels: \(labels)."
    }

    private func uniquePressureLevels(from selection: HrrrPressureProfileMessageSelectionResult) -> [Int] {
        var seen = Set<Int>()
        return selection.selectedMessages.compactMap { message in
            let pressureMb = message.pressureLevel.pressureMb
            guard seen.insert(pressureMb).inserted else {
                return nil
            }
            return pressureMb
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
