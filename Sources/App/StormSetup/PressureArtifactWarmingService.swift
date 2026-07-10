import Fluent
import FluentSQL
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

enum PressureArtifactWarmingError: Error, Sendable, CustomStringConvertible {
    case unsupportedProduct(HrrrProduct)
    case missingIdxURL
    case missingCatalogRow
    case noSelectableMessages
    case incompletePressureSelection([StormSetupPressureProfileMissingLevel])
    case validatedMessageCountMismatch(expected: Int, actual: Int)

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

    init(
        httpClient: any HTTPClient,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        validator: any PressureArtifactValidating,
        cacheRootURL: URL,
        dateProvider: any StormSetupDateProviding,
        retentionDuration: TimeInterval,
        maximumByteCount: Int,
        recoveryTimeoutSeconds: TimeInterval = 30 * 60
    ) {
        self.httpClient = httpClient
        self.validator = validator
        self.subsetCache = HrrrPressureSubsetGribCache(
            httpClient: httpClient,
            blockingWorkExecutor: blockingWorkExecutor,
            rootURL: cacheRootURL,
            dateProvider: dateProvider,
            retentionDuration: retentionDuration,
            maximumByteCount: maximumByteCount
        )
        self.dateProvider = dateProvider
        self.maximumByteCount = maximumByteCount
        self.recoveryTimeoutSeconds = max(1, recoveryTimeoutSeconds)
    }

    static func makeDefault(application: Application) -> PressureArtifactWarmingService {
        let blockingWorkExecutor = NIOThreadPoolPressureArtifactBlockingWorkExecutor(
            threadPool: application.threadPool
        )
        return PressureArtifactWarmingService(
            httpClient: VaporApplicationHTTPClient(application: application),
            blockingWorkExecutor: blockingWorkExecutor,
            validator: DefaultPressureArtifactValidationService(
                configuration: application.stormSetupConfiguration,
                runner: ProcessRunner()
            ),
            cacheRootURL: application.stormSetupConfiguration.pressureGribSubsetCacheRootURL,
            dateProvider: SystemStormSetupDateProvider(),
            retentionDuration: application.stormSetupConfiguration.gribSubsetCacheRetentionSeconds,
            maximumByteCount: application.stormSetupConfiguration.gribSubsetMaximumByteCount,
            recoveryTimeoutSeconds: application.stormSetupConfiguration.pressureArtifactRecoveryTimeoutSeconds
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

        try await ensureCatalogRowExists(for: payload, on: application.db)
        let claimToken = UUID()

        guard let claimedRow = try await claimCatalogRow(
            for: payload,
            claimToken: claimToken,
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
                "claimTokenPrefix": .string(String(claimToken.uuidString.prefix(8))),
                "leaseExpiresAt": .string(claimedRow.leaseExpiresAt?.ISO8601Format() ?? "nil")
            ]
        )

        do {
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
                        "error": .string(String(reflecting: error))
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
            guard try await markReady(
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
                        claimToken: claimToken,
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
        } catch {
            try rethrowCancellationIfNeeded(error)
            guard try await markFailed(
                payload: payload,
                claimToken: claimToken,
                error: error,
                on: application.db
            ) else {
                logger.info(
                    "Pressure artifact warm completion lost claim.",
                    metadata: claimLostMetadata(
                        payload: payload,
                        claimToken: claimToken,
                        state: "failed"
                    )
                )
                return
            }

            logger.error(
                "Pressure artifact warming failed.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validTime": .string(payload.validTime.ISO8601Format()),
                    "product": .string(payload.product.rawValue),
                    "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                    "error": .string(String(reflecting: error)),
                    "status": .string(PressureArtifactCatalogStatus.failed.rawValue)
                ]
            )
            throw error
        }
    }
}

extension PressureArtifactWarmingService {
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

        let response = try await httpClient.get(
            idxURL,
            headers: [
                "User-Agent": HTTPRequestHeaders.userAgent(),
                "Accept": "text/plain, application/octet-stream, */*"
            ]
        )
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

    func ensureCatalogRowExists(
        for payload: PressureArtifactWarmJobPayload,
        on database: any Database
    ) async throws {
        if try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        ) != nil {
            return
        }

        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: .pending
        )

        do {
            try await row.create(on: database)
        } catch {
            if DbUtils.isUniqueConstraintViolation(error) {
                return
            }

            throw error
        }
    }

    func claimCatalogRow(
        for payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let leaseExpiresAt = dateProvider.now().addingTimeInterval(recoveryTimeoutSeconds)
        let row = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.warming.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = \(bind: claimToken),
                lease_expires_at = \(bind: leaseExpiresAt)
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND (
                status IN (\(bind: PressureArtifactCatalogStatus.pending.rawValue),
                           \(bind: PressureArtifactCatalogStatus.failed.rawValue))
                OR (
                    status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
                    AND claim_token IS NULL
                    AND (
                        lease_expires_at IS NULL
                        OR lease_expires_at <= NOW()
                    )
                )
              )
            RETURNING id
            """)
            .first()

        guard row != nil else {
            return nil
        }

        return try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        )
    }

    func markReady(
        payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        localPath: String,
        byteSize: Int64,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.ready.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = \(bind: localPath),
                byte_size = \(bind: byteSize),
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func markFailed(
        payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        error: any Error,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = \(bind: String(reflecting: error)),
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
              AND claim_token = \(bind: claimToken)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func claimLostMetadata(
        payload: PressureArtifactWarmJobPayload,
        claimToken: UUID,
        state: String
    ) -> Logger.Metadata {
        [
            "runTime": .string(payload.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(payload.forecastHour),
            "validTime": .string(payload.validTime.ISO8601Format()),
            "product": .string(payload.product.rawValue),
            "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
            "claimTokenPrefix": .string(String(claimToken.uuidString.prefix(8))),
            "lostClaimState": .string(state)
        ]
    }

    func durationMilliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return Int64(components.seconds) * 1_000 + components.attoseconds / 1_000_000_000_000_000
    }
}
