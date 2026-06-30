import Foundation
import Vapor

protocol AnvilProfilePreviewProviding: Sendable {
    func previewProfile(
        for h3Cell: Int64,
        surfaceHeightMslM: Double?
    ) async throws -> AnvilAnalyzeProfilePreviewResponse
}

extension AnvilProfilePreviewProviding {
    func previewProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfilePreviewResponse {
        try await previewProfile(for: h3Cell, surfaceHeightMslM: nil)
    }
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
    private let pressureArtifactCatalogLookupService: (any PressureArtifactCatalogLookupProviding)?
    private let pressureSourceResolver: any HrrrPressureDirectObjectResolving
    private let pressureProfileLoader: any HrrrPressureProfileLoading
    private let surfaceHeightMslM: Double?
    private let requestBuilder: AnvilProfileRequestBuilder

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        pressureArtifactCatalogLookupService: (any PressureArtifactCatalogLookupProviding)? = nil,
        pressureSourceResolver: any HrrrPressureDirectObjectResolving,
        pressureProfileLoader: any HrrrPressureProfileLoading,
        surfaceHeightMslM: Double? = nil
    ) {
        self.h3Resolver = h3Resolver
        self.hrrrRunResolver = hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider)
        self.pressureArtifactCatalogLookupService = pressureArtifactCatalogLookupService
        self.pressureSourceResolver = pressureSourceResolver
        self.pressureProfileLoader = pressureProfileLoader
        self.surfaceHeightMslM = surfaceHeightMslM
        self.requestBuilder = AnvilProfileRequestBuilder(h3Resolver: h3Resolver)
    }

    init(application: Application) {
        let configuration = application.stormSetupConfiguration
        let dateProvider = SystemStormSetupDateProvider()
        let httpClient = VaporApplicationHTTPClient(application: application)
        let blockingWorkExecutor = NIOThreadPoolPressureArtifactBlockingWorkExecutor(
            threadPool: application.threadPool
        )
        let pressureArtifactCatalogLookupService = DefaultPressureArtifactCatalogLookupService(
            database: application.db,
            blockingWorkExecutor: blockingWorkExecutor,
            maximumStaleAgeSeconds: configuration.pressureArtifactMaxStaleAgeSeconds,
            logger: application.logger
        )
        let pressureSourceResolver = DefaultHrrrPressureDirectObjectResolver(httpClient: httpClient)
        let pressureProfileLoader = DefaultHrrrPressureProfileLoader(
            httpClient: httpClient,
            subsetCache: HrrrPressureSubsetGribCache(
                httpClient: httpClient,
                blockingWorkExecutor: blockingWorkExecutor,
                rootURL: configuration.pressureGribSubsetCacheRootURL,
                dateProvider: dateProvider,
                retentionDuration: configuration.gribSubsetCacheRetentionSeconds,
                maximumByteCount: configuration.gribSubsetMaximumByteCount
            ),
            fieldSampler: HrrrFieldSampler(client: configuration.makeWgrib2Client())
        )

        self.init(
            dateProvider: dateProvider,
            pressureArtifactCatalogLookupService: pressureArtifactCatalogLookupService,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader
        )
    }

    func previewProfile(
        for h3Cell: Int64,
        surfaceHeightMslM: Double? = nil
    ) async throws -> AnvilAnalyzeProfilePreviewResponse {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let runResolution = hrrrRunResolver.resolveRunCandidates()
        let selectedSurfaceHeightMslM = surfaceHeightMslM ?? self.surfaceHeightMslM
        let validatedSurfaceHeightMslM = validateSurfaceHeightMslM(selectedSurfaceHeightMslM)
        let surfaceHeightWarning = surfaceHeightWarning(for: selectedSurfaceHeightMslM, validated: validatedSurfaceHeightMslM)

        guard !runResolution.candidates.isEmpty else {
            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "No HRRR candidates were available for the preview run."
            )
        }

        var upstreamFailures: [String] = []
        var unusableProfileFailures: [String] = []
        var internalFailures: [String] = []

        if let pressureArtifactCatalogLookupService {
            let pressureResolution = HrrrRunResolution(
                targetValidTime: runResolution.targetValidTime,
                candidates: runResolution.candidates.map(makePressureCandidate(from:))
            )

            for candidate in runResolution.candidates {
                try Task.checkCancellation()
                let pressureCandidate = makePressureCandidate(from: candidate)
                do {
                    if let readyArtifact = try await pressureArtifactCatalogLookupService.readyArtifact(
                        for: pressureCandidate
                    ) {
                        try Task.checkCancellation()
                        return try await previewReadyArtifact(
                            readyArtifact,
                            h3Cell: resolved.h3Cell,
                            centroid: resolved.centroid,
                            surfaceHeightMslM: validatedSurfaceHeightMslM,
                            surfaceHeightWarning: surfaceHeightWarning
                        )
                    }
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
                    try rethrowCancellationIfNeeded(error)
                    internalFailures.append(String(describing: error))
                }
            }

            do {
                if let staleArtifact = try await pressureArtifactCatalogLookupService.staleArtifact(
                    for: pressureResolution
                ) {
                    try Task.checkCancellation()
                    return try await previewReadyArtifact(
                        staleArtifact,
                        h3Cell: resolved.h3Cell,
                        centroid: resolved.centroid,
                        staleWarning: makeStaleWarning(for: staleArtifact, targetValidTime: pressureResolution.targetValidTime),
                        surfaceHeightMslM: validatedSurfaceHeightMslM,
                        surfaceHeightWarning: surfaceHeightWarning
                    )
                }
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
                try rethrowCancellationIfNeeded(error)
                internalFailures.append(String(describing: error))
            }

            if !internalFailures.isEmpty {
                throw AnvilProfilePreviewError.internalExecutionFailure(
                    reason: internalFailures.joined(separator: "; ")
                )
            }

            if !unusableProfileFailures.isEmpty {
                throw AnvilProfilePreviewError.unusableProfile(
                    reason: unusableProfileFailures.joined(separator: "; ")
                )
            }

            if !upstreamFailures.isEmpty {
                throw AnvilProfilePreviewError.upstreamUnavailable(
                    reason: upstreamFailures.joined(separator: "; ")
                )
            }

            throw AnvilProfilePreviewError.upstreamUnavailable(
                reason: "No ready or stale pressure artifact was available for \(pressureResolution.candidates.first?.fileName ?? "the requested pressure candidate")."
            )
        }

        for candidate in runResolution.candidates {
            try Task.checkCancellation()
            let pressureCandidate = makePressureCandidate(from: candidate)
            do {
                let preview = try await previewPressureCandidate(
                    pressureCandidate,
                    h3Cell: resolved.h3Cell,
                    centroid: resolved.centroid,
                    targetValidTime: runResolution.targetValidTime,
                    surfaceHeightMslM: validatedSurfaceHeightMslM,
                    surfaceHeightWarning: surfaceHeightWarning
                )
                try Task.checkCancellation()
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
                try rethrowCancellationIfNeeded(error)
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
        targetValidTime: Date,
        surfaceHeightMslM: Double?,
        surfaceHeightWarning: String?
    ) async throws -> AnvilAnalyzeProfilePreviewResponse {
        let sourceResolution = try await resolvePressureSource(
            for: candidate,
            targetValidTime: targetValidTime
        )
        let loadResult = try await loadPressureProfile(
            sourceResolution: sourceResolution,
            centroid: centroid,
            surfaceHeightMslM: surfaceHeightMslM
        )
        try Task.checkCancellation()

        let buildResult: AnvilProfileRequestBuildResult
        do {
            buildResult = try requestBuilder.build(
                h3Cell: h3Cell,
                runTime: sourceResolution.source.runTime ?? candidate.runTime,
                forecastHour: sourceResolution.source.forecastHour ?? candidate.forecastHour,
                groupedProfile: loadResult.groupedProfile
            )
        } catch let error as AnvilProfileRequestBuilderError {
            throw classifyBuilderError(error, groupedProfile: loadResult.groupedProfile)
        } catch {
            try rethrowCancellationIfNeeded(error)
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
            pressureLevelsRequested: loadResult.selection.requestedLevels.map(\.pressureMb),
            pressureLevelsRetained: loadResult.groupedProfile.retainedLevels.map(\.pressureMb),
            missingLevels: loadResult.selection.missingLevels.map {
                AnvilAnalyzeProfilePreviewMissingLevelDTO(
                    pressureMb: $0.pressureMb,
                    missingVariables: $0.missingVariables
                )
            },
            warnings: makeWarnings(
                for: buildResult.warnings,
                ignoredSampleCount: loadResult.groupedProfile.ignoredSamples.count,
                additionalWarnings: surfaceHeightWarning.map { [$0] } ?? []
            ),
            subsetCacheHit: loadResult.subsetCacheResult.cacheHit,
            primaryDownloadURL: sourceResolution.source.primaryDownloadURL,
            idxURL: sourceResolution.source.idxURL,
            idxAvailable: sourceResolution.idxProbe.available,
            gribAvailable: sourceResolution.gribProbe?.available
        )

        return AnvilAnalyzeProfilePreviewResponse(request: request, debug: debug)
    }

    private func previewReadyArtifact(
        _ readyArtifact: PressureArtifactCatalogReadyArtifact,
        h3Cell: Int64,
        centroid: StormSetupCentroid,
        staleWarning: String? = nil,
        surfaceHeightMslM: Double?,
        surfaceHeightWarning: String?
    ) async throws -> AnvilAnalyzeProfilePreviewResponse {
        let loadResult = try await loadPressureProfile(
            readyArtifact: readyArtifact,
            centroid: centroid,
            surfaceHeightMslM: surfaceHeightMslM
        )

        let buildResult: AnvilProfileRequestBuildResult
        do {
            buildResult = try requestBuilder.build(
                h3Cell: h3Cell,
                runTime: readyArtifact.runTime,
                forecastHour: readyArtifact.forecastHour,
                groupedProfile: loadResult.groupedProfile
            )
        } catch let error as AnvilProfileRequestBuilderError {
            throw classifyBuilderError(error, groupedProfile: loadResult.groupedProfile)
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfilePreviewError.internalExecutionFailure(reason: String(describing: error))
        }

        let request = buildResult.request
        let debug = AnvilAnalyzeProfilePreviewDebugDTO(
            sourceKind: .directObject,
            product: readyArtifact.product,
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
            pressureLevelsRequested: loadResult.selection.requestedLevels.map(\.pressureMb),
            pressureLevelsRetained: loadResult.groupedProfile.retainedLevels.map(\.pressureMb),
            missingLevels: loadResult.selection.missingLevels.map {
                AnvilAnalyzeProfilePreviewMissingLevelDTO(
                    pressureMb: $0.pressureMb,
                    missingVariables: $0.missingVariables
                )
            },
            warnings: makeWarnings(
                for: buildResult.warnings,
                ignoredSampleCount: loadResult.groupedProfile.ignoredSamples.count,
                additionalWarnings: [staleWarning, surfaceHeightWarning].compactMap { $0 }
            ),
            subsetCacheHit: loadResult.subsetCacheResult.cacheHit,
            primaryDownloadURL: readyArtifact.localFileURL,
            idxURL: nil,
            idxAvailable: nil,
            gribAvailable: nil
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
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }
    }

    private func loadPressureProfile(
        sourceResolution: HrrrPressureDirectObjectResolution,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        do {
            return try await pressureProfileLoader.loadPressureProfile(
                for: sourceResolution,
                centroid: centroid,
                surfaceHeightMslM: surfaceHeightMslM
            )
        } catch let error as AnvilProfilePreviewError {
            throw error
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }
    }

    private func loadPressureProfile(
        readyArtifact: PressureArtifactCatalogReadyArtifact,
        centroid: StormSetupCentroid,
        surfaceHeightMslM: Double?
    ) async throws -> HrrrPressureProfileLoadResult {
        do {
            return try await pressureProfileLoader.loadPressureProfile(
                for: readyArtifact,
                centroid: centroid,
                surfaceHeightMslM: surfaceHeightMslM
            )
        } catch let error as AnvilProfilePreviewError {
            throw error
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: String(describing: error))
        }
    }

    private func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
        let runTime = StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: candidate.runTime) ?? candidate.runTime
        return HrrrRunCandidate(
            model: candidate.model,
            product: .wrfprsf,
            domain: candidate.domain,
            runTime: runTime,
            forecastHour: candidate.forecastHour + 1,
            fieldSetVersion: HrrrProduct.wrfprsf.defaultFieldSetVersion
        )
    }

    private func classifyBuilderError(
        _ error: AnvilProfileRequestBuilderError,
        groupedProfile: StormSetupPressureProfileGroupingResult
    ) -> AnvilProfilePreviewError {
        let droppedSummary = makeDroppedLevelsSummary(groupedProfile.droppedLevels)

        switch error {
        case .noRetainedLevels:
            return .unusableProfile(
                reason: "No retained pressure levels were available. \(droppedSummary)"
            )
        case .tooFewRetainedLevels(let actual, let minimum):
            return .unusableProfile(
                reason: "Only \(actual) retained levels were available; minimum required is \(minimum). \(droppedSummary)"
            )
        case .unequalArrayLengths(let expected, let actual):
            return .unusableProfile(
                reason: "Pressure arrays had mismatched lengths. Expected \(expected), got \(actual). \(droppedSummary)"
            )
        case .pressureNotStrictlyDescending(let previousPressureMb, let pressureMb):
            return .unusableProfile(
                reason: "Pressure levels were not strictly descending: \(previousPressureMb) then \(pressureMb). \(droppedSummary)"
            )
        }
    }

    private func makeDroppedLevelsSummary(_ levels: [StormSetupPressureProfileDroppedLevel]) -> String {
        guard !levels.isEmpty else {
            return "Missing or dropped pressure levels were not reported."
        }

        let belowGroundLabels = levels.compactMap { level -> String? in
            guard case .belowGround(let surfaceHeightMslM, let levelHeightMslM, let toleranceM) = level.reason else {
                return nil
            }
            return "\(level.pressureMb) mb below selected surface height \(surfaceHeightMslM)m (level \(levelHeightMslM)m, tolerance \(toleranceM)m)"
        }

        let incompleteLabels = levels.compactMap { level -> String? in
            guard case .incomplete(let missingVariables) = level.reason else {
                return nil
            }
            return "\(level.pressureMb) mb missing \(missingVariables.map(\.rawValue).joined(separator: ", "))"
        }

        var parts: [String] = []
        if !incompleteLabels.isEmpty {
            parts.append("Missing or incomplete levels: \(incompleteLabels.joined(separator: "; ")).")
        }
        if !belowGroundLabels.isEmpty {
            parts.append("Below-ground levels: \(belowGroundLabels.joined(separator: "; ")).")
        }

        return parts.joined(separator: " ")
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
        ignoredSampleCount: Int,
        additionalWarnings: [String] = []
    ) -> [String] {
        var values = warnings.map { warning -> String in
            switch warning {
            case .droppedLevels(let levels):
                let belowGroundLabels = levels.compactMap { level -> String? in
                    guard case .belowGround(let surfaceHeightMslM, let levelHeightMslM, let toleranceM) = level.reason else {
                        return nil
                    }
                    return "\(level.pressureMb) mb below selected surface height \(surfaceHeightMslM)m (level \(levelHeightMslM)m, tolerance \(toleranceM)m)"
                }

                let incompleteLabels = levels.compactMap { level -> String? in
                    guard case .incomplete(let missingVariables) = level.reason else {
                        return nil
                    }
                    return "\(level.pressureMb) mb missing \(missingVariables.map(\.rawValue).joined(separator: ", "))"
                }

                var labels: [String] = []
                if !belowGroundLabels.isEmpty {
                    labels.append("Dropped below-ground pressure levels: \(belowGroundLabels.joined(separator: ", ")).")
                }
                if !incompleteLabels.isEmpty {
                    labels.append("Dropped incomplete pressure levels: \(incompleteLabels.joined(separator: ", ")).")
                }
                return labels.joined(separator: " ")
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

        values.append(contentsOf: additionalWarnings)

        return values
    }

    private func makeStaleWarning(
        for readyArtifact: PressureArtifactCatalogReadyArtifact,
        targetValidTime: Date
    ) -> String {
        let ageSeconds: Int
        switch readyArtifact.freshness {
        case .exact:
            ageSeconds = 0
        case .stale(let value):
            ageSeconds = Int(value.rounded(.down))
        }

        let targetLabel = ISO8601DateFormatter().string(from: targetValidTime)
        return "Pressure artifact stale fallback selected: \(ageSeconds)s older than target valid time \(targetLabel)."
    }

    private func validateSurfaceHeightMslM(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (-500...9_000).contains(value) else {
            return nil
        }

        return value
    }

    private func surfaceHeightWarning(for selectedSurfaceHeightMslM: Double?, validated: Double?) -> String? {
        guard selectedSurfaceHeightMslM != nil else {
            return "Below-ground pressure-level filtering unavailable because selected surface height was missing."
        }

        guard validated == nil else {
            return nil
        }

        return "Below-ground pressure-level filtering unavailable because selected surface height was invalid."
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
