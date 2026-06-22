import Foundation
import Logging
import Vapor

protocol StormSetupProviding: Sendable {
    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot
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
}

protocol StormSetupIngredientNormalizing: Sendable {
    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult
}

protocol StormSetupIngredientAssessing: Sendable {
    func assess(raw: TornadoRawParameters, freshness: IngredientFreshness) -> TornadoIngredientAssessment
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
        self.logger = logger
    }

    func currentSnapshot(for h3Cell: Int64) async throws -> TornadoIngredientSnapshot {
        let resolved = try h3Resolver.resolve(h3Cell: h3Cell)
        let runResolution = hrrrRunResolver.resolveRunCandidates()

        guard !runResolution.candidates.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "No usable HRRR candidate was available.")
        }

        var failures: [StormSetupCurrentSnapshotFailure] = []

        for (index, candidate) in runResolution.candidates.enumerated() {
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
                let snapshot = try await loadSnapshot(
                    for: sourceMetadata,
                    around: resolved.centroid,
                    targetValidTime: runResolution.targetValidTime,
                    resolvedH3Cell: resolved.h3Cell
                )
                return snapshot
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

    private func loadSnapshot(
        for sourceMetadata: StormSetupSourceMetadata,
        around centroid: StormSetupCentroid,
        targetValidTime: Date,
        resolvedH3Cell: Int64
    ) async throws -> TornadoIngredientSnapshot {
        let cacheKey = try StormSetupSnapshotCacheKey(
            h3Cell: resolvedH3Cell,
            sourceMetadata: sourceMetadata,
            rulesVersion: .current
        )
        if let cached = await snapshotCache.loadSnapshot(for: cacheKey) {
            logger.info(
                "Storm Setup sampled snapshot cache hit.",
                metadata: candidateMetadata(sourceMetadata, extra: [
                    "cacheHit": .string("\(cached.cacheHit)"),
                    "fetchedAt": .string("\(cached.fetchedAt)"),
                    "expiresAt": .string("\(cached.expiresAt)")
                ])
            )
            return cached.snapshot
        }

        logger.info(
            "Storm Setup sampled snapshot cache miss.",
            metadata: candidateMetadata(sourceMetadata)
        )

        let subset = try await subsetLoader.loadFirstAvailableSubset(
            for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [makeCandidate(from: sourceMetadata)]),
            around: centroid
        )

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
        let normalized = normalizer.normalize(samples: samples)

        guard normalized.raw.nonNilFieldCount > 0 else {
            throw StormSetupCurrentSnapshotError.insufficientNormalizedData(
                source: sourceMetadata,
                reason: "wgrib2 produced no recognizable ingredient values for the selected HRRR subset."
            )
        }

        let freshness = IngredientFreshness.make(source: sourceMetadata, fetchedAt: subset.fetchedAt)
        let assessment = interpreter.assess(raw: normalized.raw, freshness: freshness)
        let snapshot = TornadoIngredientSnapshot(
            h3Cell: resolvedH3Cell,
            centroid: centroid,
            source: sourceMetadata,
            raw: normalized.raw,
            assessment: assessment,
            freshness: freshness
        )

        do {
            _ = try await snapshotCache.store(snapshot: snapshot, for: cacheKey)
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

        return snapshot
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
