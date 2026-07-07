import Foundation
import Logging
import Vapor

protocol StormSetupProviding: Sendable {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot
    func currentResponse(for h3Cell: Int64) async throws -> StormSetupCurrentResponse
}

extension StormSetupProviding {
    func currentResponse(for h3Cell: Int64) async throws -> StormSetupCurrentResponse {
        let snapshot = try await currentSnapshot(for: h3Cell)
        return StormSetupCurrentResponse(
            setup: StormSetupCurrentSetupResponse(
                h3Cell: snapshot.h3Cell,
                centroid: snapshot.centroid,
                source: snapshot.source,
                surfaceHeightMslM: snapshot.surfaceHeightMslM,
                freshness: snapshot.freshness
            ),
            ingredients: StormSetupTornadoIngredientsResponse(
                canonical: snapshot.canonicalIngredients,
                diagnostics: snapshot.raw
            ),
            profileAnalysis: nil,
            assessment: snapshot.assessment
        )
    }
}

protocol StormSetupSnapshotCaching: Sendable {
    func loadSnapshot(for key: StormSetupSnapshotCacheKey) async -> StormSetupSnapshotCacheResult?
    func store(snapshot: TornadoIngredientSnapshot, for key: StormSetupSnapshotCacheKey) async throws -> StormSetupSnapshotCacheResult
}

protocol StormSetupSubsetLoading: Sendable {
    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult
}

protocol StormSetupFieldSampling: Sendable {
    func sample(
        from subset: GribSubsetCacheResult,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample]

    func sample(
        localFileURL: URL,
        around centroid: StormSetupCentroid
    ) async throws -> [HrrrFieldSample]
}

protocol StormSetupIngredientNormalizing: Sendable {
    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult
}

protocol StormSetupIngredientAssessing: Sendable {
    func assess(
        raw: TornadoRawParameters,
        freshness: IngredientFreshness,
        evidence: AnvilIngredientEvidence?
    ) -> TornadoIngredientAssessment
}

enum StormSetupCurrentSnapshotFailureStage: String, Sendable {
    case sourceSelection
    case sampledSnapshotCache
    case gribSubsetCache
    case wgrib2Sampling
    case normalization
    case insufficientNormalizedData
    case snapshotCacheStore
}

struct StormSetupCurrentSnapshotFailure: Sendable {
    let stage: StormSetupCurrentSnapshotFailureStage
    let source: StormSetupSourceMetadata?
    let reason: String
}

enum StormSetupCurrentSnapshotError: Error, Sendable, CustomStringConvertible {
    case noUsableHrrrCandidate([StormSetupCurrentSnapshotFailure])
    case insufficientNormalizedData(source: StormSetupSourceMetadata, reason: String)

    var description: String {
        switch self {
        case .noUsableHrrrCandidate(let failures):
            let summary = failures.map { failure in
                let sourceSummary = failure.source.map { String(describing: $0) } ?? "<unknown source>"
                return "[" + failure.stage.rawValue + "] " + sourceSummary + ": " + failure.reason
            }
            .joined(separator: "; ")
            return "No usable HRRR candidate was available. \(summary)"
        case .insufficientNormalizedData(let source, let reason):
            return "Insufficient normalized ingredient data for source \(source): \(reason)"
        }
    }
}

extension StormSetupCurrentSnapshotError {
    func asAbort() -> Abort {
        switch self {
        case .noUsableHrrrCandidate(let failures):
            let status: HTTPResponseStatus = failures.contains(where: {
                $0.stage == .wgrib2Sampling || $0.stage == .snapshotCacheStore
            }) ? .internalServerError : .serviceUnavailable

            return Abort(status, reason: description)
        case .insufficientNormalizedData:
            return Abort(.unprocessableEntity, reason: description)
        }
    }
}

struct DefaultStormSetupProvider: StormSetupProviding {
    private let h3Resolver: any StormSetupH3Resolving
    private let dateProvider: any StormSetupDateProviding
    private let hrrrRunResolver: any HrrrRunResolving
    private let hrrrNomadsURLBuilder: HrrrNomadsURLBuilder
    private let snapshotCache: any StormSetupSnapshotCaching
    private let subsetLoader: any StormSetupSubsetLoading
    private let fieldSampler: any StormSetupFieldSampling
    private let normalizer: any StormSetupIngredientNormalizing
    private let interpreter: any StormSetupIngredientAssessing
    private let anvilProfileAnalysisProvider: (any AnvilProfileAnalysisProviding)?
    private let logger: Logger

    init(
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder = HrrrNomadsURLBuilder(),
        snapshotCache: any StormSetupSnapshotCaching,
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling,
        normalizer: any StormSetupIngredientNormalizing = TornadoIngredientNormalizer(),
        interpreter: any StormSetupIngredientAssessing = TornadoIngredientInterpreter(),
        anvilProfileAnalysisProvider: (any AnvilProfileAnalysisProviding)? = nil,
        logger: Logger = Logger(label: "storm-setup")
    ) {
        self.h3Resolver = h3Resolver
        self.dateProvider = dateProvider
        self.hrrrRunResolver = hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider)
        self.hrrrNomadsURLBuilder = hrrrNomadsURLBuilder
        self.snapshotCache = snapshotCache
        self.subsetLoader = subsetLoader
        self.fieldSampler = fieldSampler
        self.normalizer = normalizer
        self.interpreter = interpreter
        self.anvilProfileAnalysisProvider = anvilProfileAnalysisProvider
        self.logger = logger
    }

    init(
        h3Resolver: any StormSetupH3Resolving,
        dateProvider: any StormSetupDateProviding,
        hrrrRunResolver: any HrrrRunResolving,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder,
        snapshotCache: any StormSetupSnapshotCaching,
        subsetLoader: any StormSetupSubsetLoading,
        fieldSampler: any StormSetupFieldSampling,
        normalizer: any StormSetupIngredientNormalizing,
        interpreter: any StormSetupIngredientAssessing,
        anvilProfileAnalysisProvider: (any AnvilProfileAnalysisProviding)? = nil,
        logger: Logger
    ) {
        self.h3Resolver = h3Resolver
        self.dateProvider = dateProvider
        self.hrrrRunResolver = hrrrRunResolver
        self.hrrrNomadsURLBuilder = hrrrNomadsURLBuilder
        self.snapshotCache = snapshotCache
        self.subsetLoader = subsetLoader
        self.fieldSampler = fieldSampler
        self.normalizer = normalizer
        self.interpreter = interpreter
        self.anvilProfileAnalysisProvider = anvilProfileAnalysisProvider
        self.logger = logger
    }

    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        try await currentComposition(for: h3Cell).snapshot
    }

    func currentResponse(for h3Cell: Int64) async throws -> StormSetupCurrentResponse {
        try await currentComposition(for: h3Cell).response
    }

    private func currentComposition(for h3Cell: Int64) async throws -> StormSetupCurrentComposition {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let runResolution = hrrrRunResolver.resolveRunCandidates()

        guard !runResolution.candidates.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "No usable HRRR candidate was available.")
        }

        var failures: [StormSetupCurrentSnapshotFailure] = []

        for (index, candidate) in runResolution.candidates.enumerated() {
            try Task.checkCancellation()
            let sourceMetadata = hrrrNomadsURLBuilder.makeSourceMetadata(
                for: candidate,
                around: resolved.centroid
            )

            logCandidateAttempt(
                candidate: candidate,
                sourceMetadata: sourceMetadata,
                index: index,
                totalCount: runResolution.candidates.count
            )

            do {
                let composition = try await loadComposition(
                    for: sourceMetadata,
                    around: resolved.centroid,
                    targetValidTime: runResolution.targetValidTime,
                    resolvedH3Cell: resolved.h3Cell
                )
                return composition
            } catch let error as StormSetupCurrentSnapshotError {
                switch error {
                case .insufficientNormalizedData(let source, let reason):
                    let failure = StormSetupCurrentSnapshotFailure(
                        stage: .insufficientNormalizedData,
                        source: source,
                        reason: reason
                    )
                    failures.append(failure)
                logFailure(
                    failure,
                    sourceMetadata: sourceMetadata,
                    candidate: candidate,
                    fallbackAvailable: index < runResolution.candidates.count - 1
                )
                case .noUsableHrrrCandidate(let nestedFailures):
                    failures.append(contentsOf: nestedFailures)
                    logFailure(
                        StormSetupCurrentSnapshotFailure(
                            stage: .sourceSelection,
                            source: sourceMetadata,
                            reason: error.description
                        ),
                        sourceMetadata: sourceMetadata,
                        candidate: candidate,
                        fallbackAvailable: index < runResolution.candidates.count - 1
                    )
                }
            } catch {
                try rethrowCancellationIfNeeded(error)
                let failure = classify(error: error, sourceMetadata: sourceMetadata)
                failures.append(failure)
                logFailure(
                    failure,
                    sourceMetadata: sourceMetadata,
                    candidate: candidate,
                    fallbackAvailable: index < runResolution.candidates.count - 1
                )
            }
        }

        throw StormSetupCurrentSnapshotError.noUsableHrrrCandidate(failures)
    }

    private func loadComposition(
        for sourceMetadata: StormSetupSourceMetadata,
        around centroid: StormSetupCentroid,
        targetValidTime: Date,
        resolvedH3Cell: Int64
    ) async throws -> StormSetupCurrentComposition {
        let cacheKey = try StormSetupSnapshotCacheKey(
            h3Cell: resolvedH3Cell,
            sourceMetadata: sourceMetadata,
            rulesVersion: .current
        )
        if let cached = await snapshotCache.loadSnapshot(for: cacheKey) {
            try Task.checkCancellation()
            logger.info(
                "Storm Setup sampled snapshot cache hit.",
                metadata: candidateMetadata(sourceMetadata, extra: [
                    "cacheHit": .string("\(cached.cacheHit)"),
                    "fetchedAt": .string("\(cached.fetchedAt)"),
                    "expiresAt": .string("\(cached.expiresAt)")
                ])
            )
            return try await composeCurrentCompositionWithCurrentAnvilEvidence(from: cached.snapshot)
        }

        try Task.checkCancellation()
        logger.info(
            "Storm Setup sampled snapshot cache miss.",
            metadata: candidateMetadata(sourceMetadata)
        )

        let subset = try await subsetLoader.loadFirstAvailableSubset(
            for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [makeCandidate(from: sourceMetadata)]),
            around: centroid
        )
        try Task.checkCancellation()

        logger.info(
            "Storm Setup GRIB subset ready.",
            metadata: candidateMetadata(
                sourceMetadata,
                extra: [
                    "cacheHit": .string("\(subset.cacheHit)"),
                    "byteSize": .string("\(subset.byteSize)"),
                    "fetchedAt": .string("\(subset.fetchedAt)"),
                    "expiresAt": .string("\(subset.expiresAt)"),
                    "localFilePath": .string(subset.localFilePath)
                ]
            )
        )

        let samples = try await fieldSampler.sample(from: subset, around: centroid)
        try Task.checkCancellation()
        let normalized = normalizer.normalize(samples: samples)

        guard normalized.raw.nonNilFieldCount > 0 else {
            throw StormSetupCurrentSnapshotError.insufficientNormalizedData(
                source: sourceMetadata,
                reason: "wgrib2 produced no recognizable ingredient values for the selected HRRR subset."
            )
        }

        let freshness = IngredientFreshness.make(source: sourceMetadata, fetchedAt: subset.fetchedAt)
        let surfaceSnapshot = TornadoIngredientSnapshot(
            h3Cell: resolvedH3Cell,
            centroid: centroid,
            source: sourceMetadata,
            raw: normalized.raw,
            surfaceHeightMslM: normalized.surfaceHeightMslM,
            assessment: interpreter.assess(raw: normalized.raw, freshness: freshness, evidence: nil),
            freshness: freshness
        )

        do {
            _ = try await snapshotCache.store(snapshot: surfaceSnapshot, for: cacheKey)
            try Task.checkCancellation()
            logger.info(
                "Storm Setup sampled snapshot cached.",
                metadata: candidateMetadata(
                    sourceMetadata,
                    extra: [
                        "fetchedAt": .string("\(freshness.fetchedAt)"),
                        "expiresAt": .string("\(freshness.expiresAt)")
                    ]
                )
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            logger.warning(
                "Storm Setup sampled snapshot cache write failed.",
                metadata: candidateMetadata(
                    sourceMetadata,
                    extra: [
                        "error": .string(String(describing: error))
                    ]
                )
            )
        }

        return try await composeCurrentCompositionWithCurrentAnvilEvidence(from: surfaceSnapshot)
    }

    private func makeCandidate(from sourceMetadata: StormSetupSourceMetadata) -> HrrrRunCandidate {
        let product = sourceMetadata.product ?? .wrfsfc
        return HrrrRunCandidate(
            model: sourceMetadata.model ?? .hrrr,
            product: product,
            domain: sourceMetadata.domain ?? .conus,
            runTime: sourceMetadata.runTime ?? dateProvider.now(),
            forecastHour: sourceMetadata.forecastHour ?? 0,
            fieldSetVersion: sourceMetadata.fieldSetVersion ?? product.defaultFieldSetVersion
        )
    }

    private func resolveAnvilEvidence(
        for h3Cell: Int64,
        sourceMetadata: StormSetupSourceMetadata
    ) async throws -> AnvilEvidenceResolution {
        guard let anvilProfileAnalysisProvider else {
            return .unavailable(reason: "Anvil analysis provider is not configured.")
        }

        guard let selectedSurfaceValidTime = sourceMetadata.validTime else {
            return .unavailable(reason: "Selected surface HRRR source was missing valid time metadata.")
        }

        do {
            try Task.checkCancellation()
            let analysis = try await anvilProfileAnalysisProvider.analyzeProfile(for: h3Cell)
            try Task.checkCancellation()

            guard analysis.request.validTime == analysis.debug.validTime else {
                return .unavailable(
                    reason: "Anvil request valid time \(analysis.request.validTime) did not match debug valid time \(analysis.debug.validTime)."
                )
            }

            let pressureArtifactRunTime = analysis.debug.runTime
            let pressureArtifactForecastHour = analysis.debug.forecastHour
            let pressureArtifactValidTime = analysis.debug.validTime
            let pressureArtifactProduct = analysis.debug.product
            let staleWarnings = makeStaleWarnings(from: analysis.debug.warnings)

            if pressureArtifactValidTime == selectedSurfaceValidTime {
                return .exact(
                    evidence: AnvilIngredientEvidence(response: analysis.response),
                    profileAnalysis: analysis.response,
                    pressureArtifactRunTime: pressureArtifactRunTime,
                    pressureArtifactForecastHour: pressureArtifactForecastHour,
                    pressureArtifactValidTime: pressureArtifactValidTime,
                    pressureArtifactProduct: pressureArtifactProduct
                )
            }

            guard pressureArtifactValidTime < selectedSurfaceValidTime,
                  !staleWarnings.isEmpty else {
                return .unavailable(
                    reason: "Anvil evidence valid time \(pressureArtifactValidTime) did not match the selected surface HRRR valid time \(selectedSurfaceValidTime)."
                )
            }

            return .stale(
                evidence: AnvilIngredientEvidence(
                    response: analysis.response,
                    additionalWarnings: staleWarnings
                ),
                profileAnalysis: analysis.response,
                pressureArtifactRunTime: pressureArtifactRunTime,
                pressureArtifactForecastHour: pressureArtifactForecastHour,
                pressureArtifactValidTime: pressureArtifactValidTime,
                pressureArtifactProduct: pressureArtifactProduct,
                staleAgeSeconds: staleAgeSeconds(
                    selectedSurfaceValidTime: selectedSurfaceValidTime,
                    pressureArtifactValidTime: pressureArtifactValidTime
                )
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            return .unavailable(reason: String(describing: error))
        }
    }

    private func composeCurrentCompositionWithCurrentAnvilEvidence(
        from snapshot: TornadoIngredientSnapshot
    ) async throws -> StormSetupCurrentComposition {
        guard anvilProfileAnalysisProvider != nil else {
            let resolution = AnvilEvidenceResolution.unavailable(
                reason: "Anvil analysis provider is not configured."
            )
            logger.info(
                "Storm Setup Anvil evidence resolved.",
                metadata: anvilEvidenceResolutionMetadata(
                    source: snapshot.source,
                    resolution: resolution
                )
            )
            return StormSetupCurrentComposition(
                snapshot: snapshot,
                profileAnalysis: nil
            )
        }

        let resolution = try await resolveAnvilEvidence(
            for: snapshot.h3Cell,
            sourceMetadata: snapshot.source
        )
        try Task.checkCancellation()

        let canonicalIngredients = resolution.profileAnalysis.map {
            makeCanonicalIngredients(from: snapshot.raw, profileAnalysis: $0)
        } ?? snapshot.canonical

        let assessment = interpreter.assess(
            raw: canonicalIngredients ?? snapshot.raw,
            freshness: snapshot.freshness,
            evidence: resolution.evidence
        )

        let profileAnalysis = resolution.artifactOutcome == .exact ? resolution.profileAnalysis : nil

        let composed = TornadoIngredientSnapshot(
            h3Cell: snapshot.h3Cell,
            centroid: snapshot.centroid,
            source: snapshot.source,
            raw: snapshot.raw,
            canonical: canonicalIngredients,
            surfaceHeightMslM: snapshot.surfaceHeightMslM,
            assessment: assessment,
            freshness: snapshot.freshness,
            anvilEvidence: resolution.evidence
        )

        logger.info(
            "Storm Setup Anvil evidence resolved.",
            metadata: anvilEvidenceResolutionMetadata(
                source: composed.source,
                resolution: resolution
            )
        )

        return StormSetupCurrentComposition(
            snapshot: composed,
            profileAnalysis: profileAnalysis
        )
    }

    private func makeStaleWarnings(from warnings: [String]) -> [String] {
        warnings.filter { warning in
            warning.hasPrefix("Pressure artifact stale fallback selected:")
        }
    }

    private func anvilEvidenceResolutionMetadata(
        source: StormSetupSourceMetadata,
        resolution: AnvilEvidenceResolution
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "artifactOutcome": .string(resolution.artifactOutcome.rawValue),
            "evidenceStatus": .string(resolution.evidence.status.rawValue),
            "selectedSurfaceValidTime": .string(source.validTime?.ISO8601Format() ?? "nil"),
            "pressureArtifactValidTime": .string(resolution.pressureArtifactValidTime?.ISO8601Format() ?? "nil")
        ]

        if let pressureArtifactRunTime = resolution.pressureArtifactRunTime {
            metadata["pressureArtifactRunTime"] = .string(pressureArtifactRunTime.ISO8601Format())
        }

        if let pressureArtifactForecastHour = resolution.pressureArtifactForecastHour {
            metadata["pressureArtifactForecastHour"] = .stringConvertible(pressureArtifactForecastHour)
        }

        if let pressureArtifactProduct = resolution.pressureArtifactProduct {
            metadata["pressureArtifactProduct"] = .string(pressureArtifactProduct.rawValue)
        }

        if let staleAgeSeconds = resolution.staleAgeSeconds {
            metadata["staleAgeSeconds"] = .stringConvertible(staleAgeSeconds)
        }

        if let reason = conciseEvidenceReason(for: resolution.evidence) {
            metadata["reason"] = .string(reason)
        }

        return metadata
    }

    private func staleAgeSeconds(
        selectedSurfaceValidTime: Date,
        pressureArtifactValidTime: Date
    ) -> Int {
        max(0, Int(selectedSurfaceValidTime.timeIntervalSince(pressureArtifactValidTime).rounded(.down)))
    }

    private func conciseEvidenceReason(for evidence: AnvilIngredientEvidence) -> String? {
        switch evidence.status {
        case .available:
            return nil
        case .unavailable:
            return evidence.reason
        case .degraded:
            if let warning = evidence.diagnostics.warnings.first {
                return warning
            }
            if !evidence.diagnostics.hasEffectiveLayer {
                return "effective layer not found"
            }
            if !evidence.diagnostics.hasStormMotion {
                return "storm motion not computed"
            }
            if evidence.diagnostics.qualityProfileLevelCount < 5 {
                return "insufficient profile levels"
            }
            return "Anvil evidence is degraded."
        }
    }

    private func makeCanonicalIngredients(
        from diagnostics: TornadoRawParameters,
        profileAnalysis: AnvilAnalyzeProfileResponse
    ) -> TornadoRawParameters {
        let bunkersRightMotion = profileAnalysis.stormMotion.bunkersRight.map { bunkersRight in
            DirectionSpeed(
                directionDegrees: bunkersRight.directionTowardDeg,
                speedKt: bunkersRight.speedKt
            )
        }

        return TornadoRawParameters(
            sbcapeJkg: profileAnalysis.sbcin ?? diagnostics.sbcapeJkg,
            mlcapeJkg: profileAnalysis.mlcape ?? diagnostics.mlcapeJkg,
            mucapeJkg: profileAnalysis.mucape ?? diagnostics.mucapeJkg,
            mlcinJkg: profileAnalysis.mlcin ?? diagnostics.mlcinJkg,
            dcapeJkg: diagnostics.dcapeJkg,
            mllclM: profileAnalysis.mllclMetersAgl ?? diagnostics.mllclM,
            tempDewPtDeltaF: diagnostics.tempDewPtDeltaF,
            temperature2mK: nil,
            dewpoint2mK: nil,
            surfacePressurePa: nil,
            wind10m: nil,
            threeCapeJkg: profileAnalysis.threeCapeJkg ?? diagnostics.threeCapeJkg,
            lclLfcSeparationM: diagnostics.lclLfcSeparationM,
            lapseRate03kmCkm: profileAnalysis.lapserate03km ?? diagnostics.lapseRate03kmCkm,
            lapseRate700500mbCkm: diagnostics.lapseRate700500mbCkm,
            shear06kmKt: diagnostics.shear06kmKt,
            shear03kmKt: diagnostics.shear03kmKt,
            shear01kmKt: diagnostics.shear01kmKt,
            effectiveShearKt: profileAnalysis.effectiveBulkShearMs.map { $0 * 1.943_844_492_440_6 },
            srh01kmM2s2: profileAnalysis.srh01km ?? diagnostics.srh01kmM2s2,
            srh03kmM2s2: profileAnalysis.srh03km ?? diagnostics.srh03kmM2s2,
            effectiveSrhM2s2: profileAnalysis.effectiveSrh ?? diagnostics.effectiveSrhM2s2,
            supercellComposite: profileAnalysis.scp ?? diagnostics.supercellComposite,
            significantTornadoFixed: profileAnalysis.stpFixed ?? diagnostics.significantTornadoFixed,
            significantTornadoEffective: profileAnalysis.stpCin ?? diagnostics.significantTornadoEffective,
            significantHail: profileAnalysis.ship,
            bunkersRightMotion: bunkersRightMotion,
            bunkersLeftMotion: nil,
            stormRelativeWind46km: nil,
            meanWind850300mb: nil,
            diagnostics: nil,
            effectiveBulkShearMs: profileAnalysis.effectiveBulkShearMs,
            effectiveLayer: profileAnalysis.effectiveLayer,
            stormMotion: profileAnalysis.stormMotion
        )
    }

    private func classify(
        error: any Error,
        sourceMetadata: StormSetupSourceMetadata
    ) -> StormSetupCurrentSnapshotFailure {
        switch error {
        case let error as GribSubsetCacheError:
            return StormSetupCurrentSnapshotFailure(
                stage: .gribSubsetCache,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        case let error as NomadsGribDownloaderError:
            return StormSetupCurrentSnapshotFailure(
                stage: .gribSubsetCache,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        case let error as ProcessRunnerError:
            return StormSetupCurrentSnapshotFailure(
                stage: .wgrib2Sampling,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        case let error as Wgrib2ClientError:
            return StormSetupCurrentSnapshotFailure(
                stage: .wgrib2Sampling,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        case let error as StormSetupCurrentSnapshotError:
            return StormSetupCurrentSnapshotFailure(
                stage: .sourceSelection,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        default:
            return StormSetupCurrentSnapshotFailure(
                stage: .normalization,
                source: sourceMetadata,
                reason: String(describing: error)
            )
        }
    }

    private func logCandidateAttempt(
        candidate: HrrrRunCandidate,
        sourceMetadata: StormSetupSourceMetadata,
        index: Int,
        totalCount: Int
    ) {
        logger.info(
            index == 0
                ? "Storm Setup selected primary HRRR candidate."
                : "Storm Setup trying fallback HRRR candidate.",
            metadata: candidateMetadata(
                sourceMetadata,
                extra: [
                    "candidateIndex": .string("\(index + 1)"),
                    "candidateCount": .string("\(totalCount)"),
                    "runTime": .string("\(candidate.runTime)"),
                    "forecastHour": .string("\(candidate.forecastHour)")
                ]
            )
        )
    }

    private func logFailure(
        _ failure: StormSetupCurrentSnapshotFailure,
        sourceMetadata: StormSetupSourceMetadata,
        candidate: HrrrRunCandidate,
        fallbackAvailable: Bool
    ) {
        logger.warning(
            fallbackAvailable
                ? "Storm Setup candidate failed, trying fallback."
                : "Storm Setup candidate failed with no further fallbacks.",
            metadata: candidateMetadata(
                sourceMetadata,
                extra: [
                    "stage": .string(failure.stage.rawValue),
                    "reason": .string(failure.reason),
                    "runTime": .string("\(candidate.runTime)"),
                    "forecastHour": .string("\(candidate.forecastHour)")
                ]
            )
        )
    }

    private func candidateMetadata(
        _ sourceMetadata: StormSetupSourceMetadata,
        extra: [String: Logger.MetadataValue] = [:]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "sourceKind": .string(sourceMetadata.sourceKind.rawValue),
            "model": .string(sourceMetadata.model?.rawValue ?? "nil"),
            "product": .string(sourceMetadata.product?.rawValue ?? "nil"),
            "domain": .string(sourceMetadata.domain?.rawValue ?? "nil"),
            "runTime": .string(sourceMetadata.runTime?.description ?? "nil"),
            "forecastHour": .string(sourceMetadata.forecastHour.map(String.init) ?? "nil"),
            "validTime": .string(sourceMetadata.validTime?.description ?? "nil"),
            "fieldSetVersion": .string(sourceMetadata.fieldSetVersion?.rawValue ?? "nil"),
            "primaryDownloadURL": .string(sourceMetadata.primaryDownloadURL?.absoluteString ?? "nil")
        ]

        if let bbox = sourceMetadata.bbox {
            metadata["bbox"] = .string(
                "leftlon=\(bbox.leftlon),rightlon=\(bbox.rightlon),toplat=\(bbox.toplat),bottomlat=\(bbox.bottomlat)"
            )
        }

        for (key, value) in extra {
            metadata[key] = value
        }

        return metadata
    }
}

private struct AnvilEvidenceResolution: Sendable {
    let evidence: AnvilIngredientEvidence
    let profileAnalysis: AnvilAnalyzeProfileResponse?
    let artifactOutcome: StormSetupAnvilArtifactOutcome
    let pressureArtifactRunTime: Date?
    let pressureArtifactForecastHour: Int?
    let pressureArtifactValidTime: Date?
    let pressureArtifactProduct: HrrrProduct?
    let staleAgeSeconds: Int?

    static func exact(
        evidence: AnvilIngredientEvidence,
        profileAnalysis: AnvilAnalyzeProfileResponse,
        pressureArtifactRunTime: Date,
        pressureArtifactForecastHour: Int,
        pressureArtifactValidTime: Date,
        pressureArtifactProduct: HrrrProduct
    ) -> AnvilEvidenceResolution {
        AnvilEvidenceResolution(
            evidence: evidence,
            profileAnalysis: profileAnalysis,
            artifactOutcome: .exact,
            pressureArtifactRunTime: pressureArtifactRunTime,
            pressureArtifactForecastHour: pressureArtifactForecastHour,
            pressureArtifactValidTime: pressureArtifactValidTime,
            pressureArtifactProduct: pressureArtifactProduct,
            staleAgeSeconds: nil
        )
    }

    static func stale(
        evidence: AnvilIngredientEvidence,
        profileAnalysis: AnvilAnalyzeProfileResponse,
        pressureArtifactRunTime: Date,
        pressureArtifactForecastHour: Int,
        pressureArtifactValidTime: Date,
        pressureArtifactProduct: HrrrProduct,
        staleAgeSeconds: Int
    ) -> AnvilEvidenceResolution {
        AnvilEvidenceResolution(
            evidence: evidence,
            profileAnalysis: profileAnalysis,
            artifactOutcome: .stale,
            pressureArtifactRunTime: pressureArtifactRunTime,
            pressureArtifactForecastHour: pressureArtifactForecastHour,
            pressureArtifactValidTime: pressureArtifactValidTime,
            pressureArtifactProduct: pressureArtifactProduct,
            staleAgeSeconds: staleAgeSeconds
        )
    }

    static func unavailable(reason: String) -> AnvilEvidenceResolution {
        AnvilEvidenceResolution(
            evidence: .unavailable(reason: reason),
            profileAnalysis: nil,
            artifactOutcome: .unavailable,
            pressureArtifactRunTime: nil,
            pressureArtifactForecastHour: nil,
            pressureArtifactValidTime: nil,
            pressureArtifactProduct: nil,
            staleAgeSeconds: nil
        )
    }
}

private enum StormSetupAnvilArtifactOutcome: String, Sendable {
    case exact
    case stale
    case unavailable
}

private struct StormSetupCurrentComposition: Sendable {
    let snapshot: TornadoIngredientSnapshot
    let profileAnalysis: AnvilAnalyzeProfileResponse?

    var response: StormSetupCurrentResponse {
        StormSetupCurrentResponse(
            setup: StormSetupCurrentSetupResponse(
                h3Cell: snapshot.h3Cell,
                centroid: snapshot.centroid,
                source: snapshot.source,
                surfaceHeightMslM: snapshot.surfaceHeightMslM,
                freshness: snapshot.freshness
            ),
            ingredients: StormSetupTornadoIngredientsResponse(
                canonical: snapshot.canonicalIngredients,
                diagnostics: snapshot.raw
            ),
            profileAnalysis: profileAnalysis,
            assessment: snapshot.assessment
        )
    }
}

extension DefaultStormSetupProvider {
    init(
        application: Application,
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        hrrrRunResolver: (any HrrrRunResolving)? = nil,
        hrrrNomadsURLBuilder: HrrrNomadsURLBuilder = HrrrNomadsURLBuilder(),
        logger: Logger? = nil
    ) {
        let configuration = application.stormSetupConfiguration
        let httpClient = VaporApplicationHTTPClient(application: application)
        let subsetCache = GribSubsetCache(
            httpClient: httpClient,
            rootURL: configuration.gribSubsetCacheRootURL,
            dateProvider: dateProvider,
            retentionDuration: configuration.gribSubsetCacheRetentionSeconds,
            maximumByteCount: configuration.gribSubsetMaximumByteCount
        )
        let downloader = NomadsGribDownloader(cache: subsetCache, hrrrNomadsURLBuilder: hrrrNomadsURLBuilder)
        let sampler = HrrrFieldSampler(client: configuration.makeWgrib2Client())
        let snapshotCache = StormSetupSnapshotCache(
            rootURL: configuration.sampledSnapshotCacheRootURL,
            dateProvider: dateProvider
        )

        self.init(
            h3Resolver: h3Resolver,
            dateProvider: dateProvider,
            hrrrRunResolver: hrrrRunResolver ?? DefaultHrrrRunResolver(dateProvider: dateProvider),
            hrrrNomadsURLBuilder: hrrrNomadsURLBuilder,
            snapshotCache: snapshotCache,
            subsetLoader: downloader,
            fieldSampler: sampler,
            normalizer: TornadoIngredientNormalizer(),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: application.anvilProfileAnalysisProvider,
            logger: logger ?? application.logger
        )
    }
}

extension Application {
    var stormSetupProvider: any StormSetupProviding {
        get {
            storage[StormSetupProviderKey.self] ?? DefaultStormSetupProvider(application: self)
        }
        set {
            storage[StormSetupProviderKey.self] = newValue
        }
    }
}

private struct StormSetupProviderKey: StorageKey {
    typealias Value = any StormSetupProviding
}

extension StormSetupSnapshotCache: StormSetupSnapshotCaching {}
extension NomadsGribDownloader: StormSetupSubsetLoading {}
extension HrrrFieldSampler: StormSetupFieldSampling {}
extension TornadoIngredientNormalizer: StormSetupIngredientNormalizing {}
extension TornadoIngredientInterpreter: StormSetupIngredientAssessing {}
