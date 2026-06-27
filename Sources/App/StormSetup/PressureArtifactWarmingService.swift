import Fluent
import FluentSQL
import Foundation
import Vapor

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
        }
    }
}

struct PressureArtifactWarmingService: PressureArtifactWarming {
    private let httpClient: any HTTPClient
    private let validator: any PressureArtifactValidating
    private let subsetCache: HrrrPressureSubsetGribCache
    private let dateProvider: any StormSetupDateProviding

    init(
        httpClient: any HTTPClient,
        validator: any PressureArtifactValidating,
        cacheRootURL: URL,
        dateProvider: any StormSetupDateProviding,
        retentionDuration: TimeInterval,
        maximumByteCount: Int
    ) {
        self.httpClient = httpClient
        self.validator = validator
        self.subsetCache = HrrrPressureSubsetGribCache(
            httpClient: httpClient,
            rootURL: cacheRootURL,
            dateProvider: dateProvider,
            retentionDuration: retentionDuration,
            maximumByteCount: maximumByteCount
        )
        self.dateProvider = dateProvider
    }

    static func makeDefault(application: Application) -> PressureArtifactWarmingService {
        PressureArtifactWarmingService(
            httpClient: VaporApplicationHTTPClient(application: application),
            validator: DefaultPressureArtifactValidationService(
                configuration: application.stormSetupConfiguration,
                runner: ProcessRunner()
            ),
            cacheRootURL: application.stormSetupConfiguration.pressureGribSubsetCacheRootURL,
            dateProvider: SystemStormSetupDateProvider(),
            retentionDuration: application.stormSetupConfiguration.gribSubsetCacheRetentionSeconds,
            maximumByteCount: application.stormSetupConfiguration.gribSubsetMaximumByteCount
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

        guard let claimedRow = try await claimCatalogRow(for: payload, on: application.db) else {
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
                        "status": .string(currentRow.statusRaw),
                        "product": .string(payload.product.rawValue),
                        "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
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
                "previousStatus": .string(claimedRow.statusRaw),
                "product": .string(payload.product.rawValue),
                "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
            ]
        )

        do {
            let source = makeSourceMetadata(for: payload)
            let idxText = try await fetchIdxText(from: source, logger: logger)
            let inventory = HrrrPressureIdxInventory.parse(idxText)
            let selection = HrrrPressureProfileMessageSelector(
                preferredLevels: StormSetupPressureLevel.preferredDescending
            ).select(inventory: inventory)

            guard !selection.selectedMessages.isEmpty else {
                throw PressureArtifactWarmingError.noSelectableMessages
            }

            let byteRangePlan = HrrrGribByteRangePlanner().plan(
                inventory: inventory,
                selectedMessages: selection.selectedMessages
            )

            logger.info(
                "Selected HRRR pressure byte ranges for warming.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "selectedRangeCount": .stringConvertible(byteRangePlan.ranges.count)
                ]
            )

            let subset = try await subsetCache.loadOrFetch(
                sourceMetadata: source,
                byteRangePlan: byteRangePlan
            )

            logger.info(
                "Pressure subset cache prepared for warming.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "byteSize": .stringConvertible(subset.byteSize),
                    "cacheHit": .stringConvertible(subset.cacheHit)
                ]
            )

            let validation = try await validator.validate(localFileURL: subset.localFileURL)

            logger.info(
                "Pressure artifact validation passed.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "validatedLines": .stringConvertible(validation.stdoutLineCount)
                ]
            )

            try await markReady(
                payload: payload,
                localPath: subset.localFilePath,
                byteSize: subset.byteSize,
                on: application.db
            )

            logger.info(
                "Pressure artifact catalog row transitioned to ready.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "status": .string(PressureArtifactCatalogStatus.ready.rawValue)
                ]
            )
        } catch {
            try await markFailed(
                payload: payload,
                error: error,
                on: application.db
            )

            logger.error(
                "Pressure artifact warming failed.",
                metadata: [
                    "runTime": .string(payload.runTime.ISO8601Format()),
                    "forecastHour": .stringConvertible(payload.forecastHour),
                    "error": .string(String(reflecting: error)),
                    "status": .string(PressureArtifactCatalogStatus.failed.rawValue)
                ]
            )
            throw error
        }
    }
}

private extension PressureArtifactWarmingService {
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
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let row = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.warming.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW()
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status IN (\(bind: PressureArtifactCatalogStatus.pending.rawValue),
                             \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                             \(bind: PressureArtifactCatalogStatus.expired.rawValue))
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
        localPath: String,
        byteSize: Int64,
        on database: any Database
    ) async throws {
        guard let row = try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        ) else {
            throw PressureArtifactWarmingError.missingCatalogRow
        }

        row.status = .ready
        row.localPath = localPath
        row.byteSize = byteSize
        row.source = .aws
        row.errorSummary = nil
        row.lastCheckedAt = dateProvider.now()
        try await row.update(on: database)
    }

    func markFailed(
        payload: PressureArtifactWarmJobPayload,
        error: any Error,
        on database: any Database
    ) async throws {
        guard let row = try await PressureArtifactCatalogModel.find(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            on: database
        ) else {
            throw PressureArtifactWarmingError.missingCatalogRow
        }

        row.status = .failed
        row.localPath = nil
        row.byteSize = nil
        row.source = .aws
        row.errorSummary = String(reflecting: error)
        row.lastCheckedAt = dateProvider.now()
        try await row.update(on: database)
    }
}
