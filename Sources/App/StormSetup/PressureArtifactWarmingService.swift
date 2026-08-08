import Fluent
import Foundation
import Vapor
import ArcusCore

protocol PressureArtifactWarming: Sendable {
    func warm(
        payload: PressureArtifactWarmJobPayload,
        on application: Application,
        logger: Logger
    ) async throws
}

protocol PressureArtifactWarmTimeoutSleeping: Sendable {
    func sleep(for timeoutSeconds: TimeInterval) async throws
}

struct SystemPressureArtifactWarmTimeoutSleeper: PressureArtifactWarmTimeoutSleeping {
    func sleep(for timeoutSeconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(timeoutSeconds))
    }
}

enum PressureArtifactWarmingError: Error, Sendable, CustomStringConvertible {
    case unsupportedProduct(HrrrProduct)
    case missingIdxURL
    case missingCatalogRow
    case noSelectableMessages
    case incompletePressureSelection([StormSetupPressureProfileMissingLevel])
    case validatedMessageCountMismatch(expected: Int, actual: Int)
    case warmAttemptTimedOut(seconds: TimeInterval)

    var description: String {
        switch self {
        case .unsupportedProduct(let product):
            return "Pressure artifact warming only supports \(HrrrProduct.wrfprsf.rawValue), not \(product.rawValue)."
        case .missingIdxURL:
            return "Pressure artifact source metadata is missing an idx URL."
        case .missingCatalogRow:
            return "Pressure artifact catalog row was missing."
        case .noSelectableMessages:
            return "Pressure artifact inventory did not contain any selectable messages."
        case .incompletePressureSelection(let missingLevels):
            let details = missingLevels.map { level in
                "\(level.pressureMb) mb missing \(level.missingVariables.map(\.rawValue).joined(separator: ", "))"
            }
            .joined(separator: "; ")
            return "Pressure artifact selection is incomplete. Missing levels: \(details)."
        case .validatedMessageCountMismatch(let expected, let actual):
            return "Pressure artifact validation returned \(actual) messages, expected \(expected)."
        case .warmAttemptTimedOut(let seconds):
            return "Pressure artifact warm attempt timed out after \(Self.formattedSeconds(seconds)) seconds."
        }
    }

    private static func formattedSeconds(_ seconds: TimeInterval) -> String {
        if seconds.rounded(.towardZero) == seconds {
            return String(Int64(seconds))
        }

        return String(seconds)
    }
}

enum PressureArtifactFailureDispositionError: Error, Sendable, CustomStringConvertible {
    case completionDeferred(errorType: String)
    case completionObsolete(errorType: String)

    var errorType: String {
        switch self {
        case .completionDeferred(let errorType), .completionObsolete(let errorType):
            return errorType
        }
    }

    var logMessage: String {
        switch self {
        case .completionDeferred:
            return "PressureArtifactWarmJob left failure completion to durable queue work."
        case .completionObsolete:
            return "PressureArtifactWarmJob completed after losing its failure-completion claim."
        }
    }

    var description: String {
        switch self {
        case .completionDeferred(let errorType):
            return "Pressure artifact failure completion was deferred (\(errorType))."
        case .completionObsolete(let errorType):
            return "Pressure artifact failure completion was already obsolete (\(errorType))."
        }
    }
}

struct PressureArtifactWarmingService: PressureArtifactWarming {
    private let httpClient: any HTTPClient
    private let validator: any PressureArtifactValidating
    private let subsetCache: HrrrPressureSubsetGribCache
    private let dateProvider: any StormSetupDateProviding
    private let maximumByteCount: Int
    private let recoveryTimeoutSeconds: TimeInterval
    private let warmTimeoutSeconds: TimeInterval
    private let httpRequestTimeoutSeconds: TimeInterval
    private let timeoutSleeper: any PressureArtifactWarmTimeoutSleeping
    private let catalogStore: PressureArtifactCatalogStore
    private let failureCompleter: any PressureArtifactFailureCompleting
    private let failureCompletionDispatcher: any PressureArtifactFailureCompletionJobDispatching

    init(
        httpClient: any HTTPClient,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        validator: any PressureArtifactValidating,
        cacheRootURL: URL,
        dateProvider: any StormSetupDateProviding,
        retentionDuration: TimeInterval,
        maximumByteCount: Int,
        recoveryTimeoutSeconds: TimeInterval = 30 * 60,
        warmTimeoutSeconds: TimeInterval = StormSetupConfiguration.defaultPressureArtifactWarmTimeoutSeconds,
        httpRequestTimeoutSeconds: TimeInterval = 30,
        timeoutSleeper: any PressureArtifactWarmTimeoutSleeping = SystemPressureArtifactWarmTimeoutSleeper(),
        catalogStore: PressureArtifactCatalogStore = PressureArtifactCatalogStore(),
        failureCompleter: (any PressureArtifactFailureCompleting)? = nil,
        failureCompletionDispatcher: any PressureArtifactFailureCompletionJobDispatching = DefaultPressureArtifactFailureCompletionJobDispatcher()
    ) {
        self.httpClient = httpClient
        self.validator = validator
        self.subsetCache = HrrrPressureSubsetGribCache(
            httpClient: httpClient,
            blockingWorkExecutor: blockingWorkExecutor,
            rootURL: cacheRootURL,
            dateProvider: dateProvider,
            retentionDuration: retentionDuration,
            maximumByteCount: maximumByteCount,
            requestTimeoutSeconds: httpRequestTimeoutSeconds
        )
        self.dateProvider = dateProvider
        self.maximumByteCount = maximumByteCount
        self.recoveryTimeoutSeconds = StormSetupConfiguration.normalizedPressureArtifactRecoveryTimeoutSeconds(
            recoveryTimeoutSeconds
        )
        self.warmTimeoutSeconds = StormSetupConfiguration.resolvedPressureArtifactWarmTimeoutSeconds(
            warmTimeoutSeconds,
            recoveryTimeoutSeconds: self.recoveryTimeoutSeconds
        )
        self.httpRequestTimeoutSeconds = httpRequestTimeoutSeconds
        self.timeoutSleeper = timeoutSleeper
        self.catalogStore = catalogStore
        self.failureCompleter = failureCompleter ?? DefaultPressureArtifactFailureCompleter(catalogStore: catalogStore)
        self.failureCompletionDispatcher = failureCompletionDispatcher
    }

    static func makeDefault(
        application: Application,
        httpClient: (any HTTPClient)? = nil,
        validator: (any PressureArtifactValidating)? = nil,
        dateProvider: (any StormSetupDateProviding)? = nil
    ) -> PressureArtifactWarmingService {
        let configuration = application.stormSetupConfiguration
        let blockingWorkExecutor = NIOThreadPoolPressureArtifactBlockingWorkExecutor(
            threadPool: application.threadPool
        )
        return PressureArtifactWarmingService(
            httpClient: httpClient ?? VaporApplicationHTTPClient(application: application),
            blockingWorkExecutor: blockingWorkExecutor,
            validator: validator ?? DefaultPressureArtifactValidationService(
                configuration: configuration,
                runner: ProcessRunner()
            ),
            cacheRootURL: configuration.pressureGribSubsetCacheRootURL,
            dateProvider: dateProvider ?? SystemStormSetupDateProvider(),
            retentionDuration: configuration.gribSubsetCacheRetentionSeconds,
            maximumByteCount: configuration.gribSubsetMaximumByteCount,
            recoveryTimeoutSeconds: configuration.pressureArtifactRecoveryTimeoutSeconds,
            warmTimeoutSeconds: configuration.pressureArtifactWarmTimeoutSeconds,
            httpRequestTimeoutSeconds: configuration.pressureArtifactHTTPTimeoutSeconds
        )
    }

    func warm(
        payload: PressureArtifactWarmJobPayload,
        on application: Application,
        logger: Logger
    ) async throws {
        guard payload.product == .wrfprsf else {
            throw PressureArtifactWarmingError.unsupportedProduct(payload.product)
        }

        try await catalogStore.ensureCatalogRowExists(for: payload, on: application.db)
        let claimToken = UUID()
        let leaseExpiresAt = dateProvider.now().addingTimeInterval(recoveryTimeoutSeconds)

        guard let claimedRow = try await catalogStore.claimCatalogRow(
            for: payload,
            claimToken: claimToken,
            leaseExpiresAt: leaseExpiresAt,
            on: application.db
        ) else {
            try Task.checkCancellation()
            let currentRow = try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: application.db
            )

            if let currentRow {
                logger.info(
                    "Pressure artifact warm skipped.",
                    metadata: [
                        "runTime": .string(payload.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(payload.forecastHour),
                        "validTime": .string(payload.validTime.ISO8601Format()),
                        "status": .string(currentRow.statusRaw),
                        "product": .string(payload.product.rawValue),
                        "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                        "catalogSkipReason": .string("existing catalog state")
                    ]
                )
                return
            }

            throw PressureArtifactWarmingError.missingCatalogRow
        }

        logger.info(
            "Pressure artifact catalog row claimed for warming.",
            metadata: [
                "runTime": .string(payload.runTime.ISO8601Format()),
                "forecastHour": .stringConvertible(payload.forecastHour),
                "validTime": .string(payload.validTime.ISO8601Format()),
                "previousStatus": .string(claimedRow.statusRaw),
                "status": .string(PressureArtifactCatalogStatus.warming.rawValue),
                "product": .string(payload.product.rawValue),
                "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                "leaseExpiresAt": .string(claimedRow.leaseExpiresAt?.ISO8601Format() ?? "nil")
            ]
        )

        do {
            try await withWarmAttemptTimeout {
            let source = makeSourceMetadata(for: payload)
            let idxText = try await fetchIdxText(from: source, logger: logger)
            try Task.checkCancellation()
            let inventory = HrrrPressureIdxInventory.parse(idxText)
            let selection = HrrrPressureProfileMessageSelector(
                preferredLevels: StormSetupPressureLevel.preferredDescending
            ).select(inventory: inventory)

            guard selection.missingLevels.isEmpty else {
                throw PressureArtifactWarmingError.incompletePressureSelection(selection.missingLevels)
            }

            guard !selection.selectedMessages.isEmpty else {
                throw PressureArtifactWarmingError.noSelectableMessages
            }

            logger.info(
                "Selected HRRR pressure messages for warming.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "requestedLevelCount": .stringConvertible(selection.requestedLevels.count),
                    "selectedPressureLevelCount": .stringConvertible(Set(selection.selectedMessages.map(\.pressureLevel)).count),
                    "selectedMessageCount": .stringConvertible(selection.selectedMessages.count),
                    "missingLevelCount": .stringConvertible(selection.missingLevels.count)
                ]
            )

            let byteRangePlan = HrrrGribByteRangePlanner().plan(
                inventory: inventory,
                selectedMessages: selection.selectedMessages
            )

            logger.info(
                "Selected HRRR pressure byte ranges for warming.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "selectedRangeCount": .stringConvertible(byteRangePlan.ranges.count)
                ]
            )

            let clock = ContinuousClock()
            let downloadStart = clock.now
            let subset = try await subsetCache.loadOrFetch(
                sourceMetadata: source,
                byteRangePlan: byteRangePlan
            )
            try Task.checkCancellation()
            let downloadDuration = downloadStart.duration(to: clock.now)
            let downloadDurationMs = durationMilliseconds(downloadDuration)

            logger.info(
                "Pressure subset cache prepared for warming.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "sourceURL": .string(source.primaryDownloadURL?.absoluteString ?? "nil"),
                    "idxURL": .string(source.idxURL?.absoluteString ?? "nil"),
                    "cacheHit": .stringConvertible(subset.cacheHit),
                    "artifactByteSize": .stringConvertible(subset.byteSize),
                    "maximumByteCount": .stringConvertible(maximumByteCount),
                    "downloadDurationMs": .stringConvertible(downloadDurationMs)
                ]
            )

            let validation: PressureArtifactValidationResult
            do {
                validation = try await validator.validate(localFileURL: subset.localFileURL)
                try Task.checkCancellation()
            } catch {
                try rethrowCancellationIfNeeded(error)
                try await subsetCache.invalidate(
                    sourceMetadata: source,
                    byteRangePlan: byteRangePlan
                )
                logger.error(
                    "Pressure artifact validation failed.",
                    metadata: [
                        "runTime": .string(payload.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(payload.forecastHour),
                        "validTime": .string(payload.validTime.ISO8601Format()),
                        "product": .string(payload.product.rawValue),
                        "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                        "status": .string(PressureArtifactCatalogStatus.failed.rawValue),
                        "error": .string(PressureArtifactFailureSummary.sanitized(
                            from: error,
                            claimToken: claimToken
                        ))
                    ]
                )
                throw error
            }

            try Task.checkCancellation()
            guard validation.stdoutLineCount == selection.selectedMessages.count else {
                try await subsetCache.invalidate(
                    sourceMetadata: source,
                    byteRangePlan: byteRangePlan
                )
                throw PressureArtifactWarmingError.validatedMessageCountMismatch(
                    expected: selection.selectedMessages.count,
                    actual: validation.stdoutLineCount
                )
            }

            logger.info(
                "Pressure artifact validation passed.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "validatedLines": .stringConvertible(validation.stdoutLineCount),
                    "status": .string(PressureArtifactCatalogStatus.ready.rawValue)
                ]
            )

            try Task.checkCancellation()
            guard try await catalogStore.markReady(
                payload: payload,
                claimToken: claimToken,
                localPath: subset.localFilePath,
                byteSize: subset.byteSize,
                on: application.db
            ) else {
                logger.info(
                    "Pressure artifact warm completion lost claim.",
                    metadata: claimLostMetadata(
                        payload: payload,
                        state: "ready"
                    )
                )
                return
            }

            logger.info(
                "Pressure artifact catalog row transitioned to ready.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "status": .string(PressureArtifactCatalogStatus.ready.rawValue)
                ]
            )
            }
        } catch {
            try rethrowCancellationIfNeeded(error)
            let acquisitionError = error
            let timeoutSeconds = ownedTimeoutSeconds(from: acquisitionError)
            let errorSummary = PressureArtifactFailureSummary.sanitized(
                from: acquisitionError,
                claimToken: claimToken
            )
            let completionPayload = PressureArtifactFailureCompletionJobPayload(
                artifact: payload,
                claimToken: claimToken,
                errorSummary: errorSummary
            )
            let completedFailure: Bool
            do {
                completedFailure = try await failureCompleter.complete(
                    completionPayload,
                    on: application
                )
            } catch {
                try rethrowCancellationIfNeeded(error)
                do {
                    try await failureCompletionDispatcher.dispatch(
                        completionPayload,
                        on: application
                    )
                } catch {
                    try rethrowCancellationIfNeeded(error)
                    throw PressureArtifactFailureCompletionError.dispatchFailed(
                        errorType: String(describing: type(of: error))
                    )
                }

                logger.error(
                    "Pressure artifact failure completion deferred to durable queue work.",
                    metadata: claimLostMetadata(
                        payload: payload,
                        state: "failure completion deferred"
                    )
                )
                throw PressureArtifactFailureDispositionError.completionDeferred(
                    errorType: String(describing: type(of: acquisitionError))
                )
            }

            guard completedFailure else {
                logger.info(
                    "Pressure artifact warm completion lost claim.",
                    metadata: claimLostMetadata(
                        payload: payload,
                        state: "failed"
                    )
                )
                throw PressureArtifactFailureDispositionError.completionObsolete(
                    errorType: String(describing: type(of: acquisitionError))
                )
            }

            if let timeoutSeconds {
                logger.error(
                    "Pressure artifact warm attempt timed out.",
                    metadata: [
                        "runTime": .string(payload.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(payload.forecastHour),
                        "validTime": .string(payload.validTime.ISO8601Format()),
                        "product": .string(payload.product.rawValue),
                        "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                        "error": .string(errorSummary),
                        "status": .string(PressureArtifactCatalogStatus.failed.rawValue),
                        "warmTimeoutSeconds": .stringConvertible(timeoutSeconds)
                    ]
                )
            } else {
                logger.error(
                    "Pressure artifact warming failed.",
                    metadata: [
                        "runTime": .string(payload.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(payload.forecastHour),
                        "validTime": .string(payload.validTime.ISO8601Format()),
                        "product": .string(payload.product.rawValue),
                        "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                        "error": .string(errorSummary),
                        "status": .string(PressureArtifactCatalogStatus.failed.rawValue)
                    ]
                )
            }
            throw acquisitionError
        }
    }
}

extension PressureArtifactWarmingService {
    func withWarmAttemptTimeout(
        operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await timeoutSleeper.sleep(for: warmTimeoutSeconds)
                try Task.checkCancellation()
                throw PressureArtifactWarmingError.warmAttemptTimedOut(seconds: warmTimeoutSeconds)
            }
            defer { group.cancelAll() }

            _ = try await group.next()
        }
    }

    func ownedTimeoutSeconds(from error: any Error) -> TimeInterval? {
        guard case .warmAttemptTimedOut(let seconds) = error as? PressureArtifactWarmingError else {
            return nil
        }

        return seconds
    }

    func makeSourceMetadata(for payload: PressureArtifactWarmJobPayload) -> StormSetupSourceMetadata {
        let candidate = HrrrRunCandidate(
            product: payload.product,
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            fieldSetVersion: payload.fieldSetVersion
        )
        let builder = HrrrPressureDirectObjectURLBuilder()

        return StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: candidate.model,
            product: payload.product,
            domain: candidate.domain,
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            fieldSetVersion: payload.fieldSetVersion,
            primaryDownloadURL: builder.makeGribURL(for: candidate),
            idxURL: builder.makeIdxURL(for: candidate)
        )
    }

    func fetchIdxText(
        from source: StormSetupSourceMetadata,
        logger: Logger
    ) async throws -> String {
        guard let idxURL = source.idxURL else {
            throw PressureArtifactWarmingError.missingIdxURL
        }

        let response: HTTPResponse
        do {
            response = try await httpClient.get(
                idxURL,
                headers: [
                    "User-Agent": HTTPRequestHeaders.userAgent(),
                    "Accept": "text/plain, application/octet-stream, */*"
                ],
                timeoutSeconds: httpRequestTimeoutSeconds
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw PressureArtifactAcquisitionError.classify(error)
        }
        try Task.checkCancellation()

        guard (200...299).contains(response.status) else {
            throw Abort(.badGateway, reason: "Pressure idx request returned HTTP \(response.status).")
        }

        guard let body = response.data, !body.isEmpty else {
            throw Abort(.badGateway, reason: "Pressure idx request returned an empty body.")
        }

        guard let text = String(data: body, encoding: .utf8) else {
            throw Abort(.badGateway, reason: "Pressure idx request returned invalid UTF-8.")
        }

        logger.info(
            "Fetched HRRR pressure idx inventory.",
            metadata: [
                "runTime": .string(source.runTime?.ISO8601Format() ?? "unknown"),
                "forecastHour": .stringConvertible(source.forecastHour ?? -1),
                "validTime": .string(source.validTime?.ISO8601Format() ?? "unknown"),
                "product": .string(source.product?.rawValue ?? "unknown"),
                "fieldSetVersion": .string(source.fieldSetVersion?.rawValue ?? "unknown"),
                "sourceURL": .string(source.primaryDownloadURL?.absoluteString ?? "nil"),
                "idxURL": .string(source.idxURL?.absoluteString ?? "nil"),
                "idxLineCount": .stringConvertible(text.split(whereSeparator: \.isNewline).count)
            ]
        )

        return text
    }

    func claimLostMetadata(
        payload: PressureArtifactWarmJobPayload,
        state: String
    ) -> Logger.Metadata {
        [
            "runTime": .string(payload.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(payload.forecastHour),
            "validTime": .string(payload.validTime.ISO8601Format()),
            "product": .string(payload.product.rawValue),
            "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
            "lostClaimState": .string(state)
        ]
    }

    func durationMilliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return Int64(components.seconds) * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
