import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor
import ArcusCore

protocol HRRRPressureArtifactProbing: Sendable {
    func probe(on application: Application, logger: Logger) async throws
}

protocol PressureArtifactWarmJobDispatching: Sendable {
    func dispatch(
        _ payload: PressureArtifactWarmJobPayload,
        to queueName: QueueName,
        on application: Application
    ) async throws
}

struct DefaultPressureArtifactWarmJobDispatcher: PressureArtifactWarmJobDispatching {
    func dispatch(
        _ payload: PressureArtifactWarmJobPayload,
        to queueName: QueueName,
        on application: Application
    ) async throws {
        try await application.queues
            .queue(queueName)
            .dispatch(PressureArtifactWarmJob.self, payload)
    }
}

enum HRRRPressureArtifactProbeError: Error, Sendable, CustomStringConvertible {
    case unsupportedProduct(HrrrProduct)
    case missingCatalogRow
    case databaseNotSQL

    var description: String {
        switch self {
        case .unsupportedProduct(let product):
            return "HRRR pressure artifact probing only supports \(HrrrProduct.wrfprsf.rawValue), not \(product.rawValue)."
        case .missingCatalogRow:
            return "HRRR pressure artifact catalog row was missing."
        case .databaseNotSQL:
            return "HRRR pressure artifact probe requires an SQL database."
        }
    }
}

struct HRRRPressureArtifactProbeService: HRRRPressureArtifactProbing {
    private let runResolver: any HrrrRunResolving
    private let remoteObjectChecker: any HrrrRemoteObjectChecking
    private let warmJobDispatcher: any PressureArtifactWarmJobDispatching
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let dateProvider: any StormSetupDateProviding
    private let recoveryTimeoutSeconds: TimeInterval
    private let urlBuilder: HrrrPressureDirectObjectURLBuilder

    init(
        runResolver: any HrrrRunResolving = DefaultHrrrRunResolver(),
        remoteObjectChecker: any HrrrRemoteObjectChecking,
        warmJobDispatcher: any PressureArtifactWarmJobDispatching = DefaultPressureArtifactWarmJobDispatcher(),
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        recoveryTimeoutSeconds: TimeInterval = 30 * 60,
        urlBuilder: HrrrPressureDirectObjectURLBuilder = HrrrPressureDirectObjectURLBuilder()
    ) {
        self.runResolver = runResolver
        self.remoteObjectChecker = remoteObjectChecker
        self.warmJobDispatcher = warmJobDispatcher
        self.blockingWorkExecutor = blockingWorkExecutor
        self.dateProvider = dateProvider
        self.recoveryTimeoutSeconds = max(1, recoveryTimeoutSeconds)
        self.urlBuilder = urlBuilder
    }

    static func makeDefault(application: Application) -> HRRRPressureArtifactProbeService {
        HRRRPressureArtifactProbeService(
            remoteObjectChecker: HTTPHrrrRemoteObjectChecker(
                httpClient: VaporApplicationHTTPClient(application: application)
            ),
            blockingWorkExecutor: NIOThreadPoolPressureArtifactBlockingWorkExecutor(
                threadPool: application.threadPool
            ),
            dateProvider: SystemStormSetupDateProvider(),
            recoveryTimeoutSeconds: application.stormSetupConfiguration.pressureArtifactRecoveryTimeoutSeconds
        )
    }

    func probe(on application: Application, logger: Logger) async throws {
        let resolution = runResolver.resolveRunCandidates()
        let now = dateProvider.now()
        let recoveryCutoff = now.addingTimeInterval(-recoveryTimeoutSeconds)

        logger.info(
            "HRRR pressure artifact probe started.",
            metadata: [
                "targetValidTime": .string(resolution.targetValidTime.ISO8601Format()),
                "candidateCount": .stringConvertible(resolution.candidates.count)
            ]
        )

        for candidate in resolution.candidates {
            try Task.checkCancellation()
            let pressureCandidate = makePressureCandidate(from: candidate)
            let source = urlBuilder.makeSourceMetadata(for: pressureCandidate)
            guard let idxURL = source.idxURL else {
                logger.warning(
                    "HRRR pressure artifact probe skipped candidate with missing idx URL.",
                    metadata: candidateMetadata(
                        for: pressureCandidate,
                        source: source,
                        extra: [
                            "catalogSkipReason": .string("missing idx URL")
                        ]
                    )
                )
                try Task.checkCancellation()
                continue
            }

            let idxProbe = try await remoteObjectChecker.probe(url: idxURL)
            let payload = makePayload(from: pressureCandidate)

            logger.info(
                "HRRR pressure artifact idx availability checked.",
                metadata: candidateMetadata(
                    for: pressureCandidate,
                    source: source,
                    idxURL: idxURL,
                    idxProbe: idxProbe
                )
            )

            if idxProbe.available {
                do {
                    try Task.checkCancellation()
                    let currentRow = try await PressureArtifactCatalogModel.find(
                        runTime: payload.runTime,
                        forecastHour: payload.forecastHour,
                        product: payload.product,
                        fieldSetVersion: payload.fieldSetVersion,
                        on: application.db
                    )

                    if let currentRow, currentRow.status == .ready {
                        if try await isUsableReadyCatalogRow(currentRow) {
                            logger.info(
                                "HRRR pressure artifact warm skipped for existing catalog state.",
                                metadata: skipMetadata(
                                    for: pressureCandidate,
                                    source: source,
                                    idxURL: idxURL,
                                    idxProbe: idxProbe,
                                    catalogStatus: currentRow.statusRaw,
                                    reason: "catalog state is ready and usable"
                                )
                            )
                            return
                        }

                        guard try await recoverUnusableReadyCatalogRow(
                            currentRow,
                            payload: payload,
                            on: application.db
                        ) else {
                            logger.info(
                                "HRRR pressure artifact warm skipped for existing catalog state.",
                                metadata: skipMetadata(
                                    for: pressureCandidate,
                                    source: source,
                                    idxURL: idxURL,
                                    idxProbe: idxProbe,
                                    catalogStatus: currentRow.statusRaw,
                                    reason: "catalog state changed before ready recovery"
                                )
                            )
                            return
                        }

                        try Task.checkCancellation()
                        try await warmJobDispatcher.dispatch(
                            payload,
                            to: ArcusQueueLane.modelArtifacts.queueName,
                            on: application
                        )

                        logger.info(
                            "HRRR pressure artifact ready row recovered for warming.",
                            metadata: recoveryMetadata(
                                for: pressureCandidate,
                                source: source,
                                idxURL: idxURL,
                                idxProbe: idxProbe,
                                queueName: ArcusQueueLane.modelArtifacts.queueName.string,
                                recoveryReason: "unusable ready file"
                            )
                        )
                        return
                    }

                    try Task.checkCancellation()
                    guard try await claimWarmableCatalogRow(
                        for: payload,
                        recoveryCutoff: recoveryCutoff,
                        on: application.db
                    ) else {
                        logger.info(
                            "HRRR pressure artifact warm skipped for existing catalog state.",
                            metadata: skipMetadata(
                                for: pressureCandidate,
                                source: source,
                                idxURL: idxURL,
                                idxProbe: idxProbe,
                                catalogStatus: currentRow?.statusRaw,
                                reason: catalogSkipReason(for: currentRow, recoveryCutoff: recoveryCutoff)
                            )
                        )
                        return
                    }

                    try Task.checkCancellation()
                    try await warmJobDispatcher.dispatch(
                        payload,
                        to: ArcusQueueLane.modelArtifacts.queueName,
                        on: application
                    )

                    logger.info(
                        "HRRR pressure artifact warm enqueued.",
                        metadata: recoveryMetadata(
                            for: pressureCandidate,
                            source: source,
                            idxURL: idxURL,
                            idxProbe: idxProbe,
                            queueName: ArcusQueueLane.modelArtifacts.queueName.string,
                            recoveryReason: recoveryReason(for: currentRow, recoveryCutoff: recoveryCutoff)
                        )
                    )
                    return
                } catch {
                    try rethrowCancellationIfNeeded(error)
                    try await markProbeFailure(
                        payload: payload,
                        error: error,
                        on: application.db
                    )
                    logger.error(
                        "HRRR pressure artifact probe failed while enqueueing warm job.",
                        metadata: recoveryMetadata(
                            for: pressureCandidate,
                            source: source,
                            idxURL: idxURL,
                            idxProbe: idxProbe,
                            queueName: ArcusQueueLane.modelArtifacts.queueName.string,
                            error: error
                        )
                    )
                    throw error
                }
            }

            try Task.checkCancellation()
            try await markUnavailability(
                payload: payload,
                idxURL: idxURL,
                idxProbe: idxProbe,
                on: application.db
            )
            logger.info(
                "HRRR pressure artifact idx unavailable.",
                metadata: unavailabilityMetadata(
                    for: pressureCandidate,
                    source: source,
                    idxURL: idxURL,
                    idxProbe: idxProbe
                )
            )
        }

        logger.info(
            "HRRR pressure artifact probe finished without an available candidate.",
            metadata: ["targetValidTime": .string(resolution.targetValidTime.ISO8601Format())]
        )
    }
}

private extension HRRRPressureArtifactProbeService {
    func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
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

    func makePayload(from candidate: HrrrRunCandidate) -> PressureArtifactWarmJobPayload {
        PressureArtifactWarmJobPayload(
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: candidate.validTime,
            product: candidate.product,
            fieldSetVersion: candidate.fieldSetVersion
        )
    }

    func claimWarmableCatalogRow(
        for payload: PressureArtifactWarmJobPayload,
        recoveryCutoff: Date,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw HRRRPressureArtifactProbeError.databaseNotSQL
        }

        let row = try await sql.raw("""
            INSERT INTO pressure_artifact_catalog (
                id,
                run_time,
                forecast_hour,
                valid_time,
                product,
                field_set_version,
                status,
                source,
                last_checked_at,
                error_summary,
                local_path,
                byte_size,
                claim_token,
                lease_expires_at
            ) VALUES (
                gen_random_uuid(),
                \(bind: payload.runTime),
                \(bind: payload.forecastHour),
                \(bind: payload.validTime),
                \(bind: payload.product.rawValue),
                \(bind: payload.fieldSetVersion.rawValue),
                \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                \(bind: PressureArtifactCatalogSource.aws.rawValue),
                NOW(),
                NULL,
                NULL,
                NULL,
                NULL,
                NULL
            )
            ON CONFLICT (run_time, forecast_hour, product, field_set_version)
            DO UPDATE SET
                status = \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE pressure_artifact_catalog.status IN (
                \(bind: PressureArtifactCatalogStatus.failed.rawValue)
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.pending.rawValue)
                AND pressure_artifact_catalog.last_checked_at < \(bind: recoveryCutoff)
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.warming.rawValue)
                AND (
                    pressure_artifact_catalog.lease_expires_at IS NULL
                    OR pressure_artifact_catalog.lease_expires_at <= NOW()
                )
            )
            OR (
                pressure_artifact_catalog.status = \(bind: PressureArtifactCatalogStatus.expired.rawValue)
                AND pressure_artifact_catalog.claim_token IS NULL
                AND (
                    pressure_artifact_catalog.lease_expires_at IS NULL
                    OR pressure_artifact_catalog.lease_expires_at <= NOW()
                )
            )
            RETURNING id
            """)
            .first()

        return row != nil
    }

    func recoverUnusableReadyCatalogRow(
        _ row: PressureArtifactCatalogModel,
        payload: PressureArtifactWarmJobPayload,
        on database: any Database
    ) async throws -> Bool {
        guard let sql = database as? any SQLDatabase else {
            throw HRRRPressureArtifactProbeError.databaseNotSQL
        }

        let updatedRow = try await sql.raw("""
            UPDATE pressure_artifact_catalog
            SET status = \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL,
                claim_token = NULL,
                lease_expires_at = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
              AND status = \(bind: PressureArtifactCatalogStatus.ready.rawValue)
            RETURNING id
            """)
            .first()

        return updatedRow != nil
    }

    func markUnavailability(
        payload: PressureArtifactWarmJobPayload,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw HRRRPressureArtifactProbeError.databaseNotSQL
        }

        _ = try await sql.raw("""
            INSERT INTO pressure_artifact_catalog (
                id,
                run_time,
                forecast_hour,
                valid_time,
                product,
                field_set_version,
                status,
                source,
                last_checked_at,
                error_summary
            ) VALUES (
                gen_random_uuid(),
                \(bind: payload.runTime),
                \(bind: payload.forecastHour),
                \(bind: payload.validTime),
                \(bind: payload.product.rawValue),
                \(bind: payload.fieldSetVersion.rawValue),
                \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                \(bind: PressureArtifactCatalogSource.aws.rawValue),
                NOW(),
                \(bind: makeUnavailableSummary(idxURL: idxURL, idxProbe: idxProbe))
            )
            ON CONFLICT (run_time, forecast_hour, product, field_set_version)
            DO UPDATE SET
                last_checked_at = NOW()
            RETURNING id
            """)
            .first()
    }

    func markProbeFailure(
        payload: PressureArtifactWarmJobPayload,
        error: any Error,
        on database: any Database
    ) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw HRRRPressureArtifactProbeError.databaseNotSQL
        }

        _ = try await sql.raw("""
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
            RETURNING id
            """)
            .first()
    }

    func isUsableReadyCatalogRow(_ row: PressureArtifactCatalogModel) async throws -> Bool {
        guard let localPath = row.localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !localPath.isEmpty else {
            return false
        }

        let localURL = URL(fileURLWithPath: localPath)
        let fileIsUsable: Bool
        do {
            fileIsUsable = try await blockingWorkExecutor.execute {
                let fileAttributes = try FileManager.default.attributesOfItem(atPath: localURL.path)
                guard let fileType = fileAttributes[.type] as? FileAttributeType,
                      fileType == .typeRegular,
                      let fileSize = fileAttributes[.size] as? NSNumber,
                      fileSize.int64Value > 0 else {
                    return false
                }

                return true
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }

        return fileIsUsable
    }

    func recoveryReason(
        for row: PressureArtifactCatalogModel?,
        recoveryCutoff: Date
    ) -> String? {
        guard let row else { return nil }

        switch row.status {
        case .pending:
            guard let lastCheckedAt = row.lastCheckedAt, lastCheckedAt < recoveryCutoff else {
                return nil
            }
            return "stale pending row"
        case .warming:
            guard let leaseExpiresAt = row.leaseExpiresAt, leaseExpiresAt <= dateProvider.now() else {
                return nil
            }
            return "expired warming lease"
        case .failed:
            return "failed row"
        case .expired:
            if row.claimToken != nil {
                if let leaseExpiresAt = row.leaseExpiresAt, leaseExpiresAt > dateProvider.now() {
                    return "active cleanup claim"
                }

                return "cleanup claim present"
            }

            return "expired row"
        case .ready:
            return nil
        }
    }

    func catalogSkipReason(
        for row: PressureArtifactCatalogModel?,
        recoveryCutoff: Date
    ) -> String {
        guard let row else {
            return "catalog row missing"
        }

        switch row.status {
        case .pending:
            if let lastCheckedAt = row.lastCheckedAt, lastCheckedAt >= recoveryCutoff {
                return "recent pending row"
            }
            return "pending row without recovery eligibility"
        case .warming:
            if let leaseExpiresAt = row.leaseExpiresAt, leaseExpiresAt > dateProvider.now() {
                return "actively leased warming row"
            }
            return "warming row without recovery eligibility"
        case .ready:
            return "ready row is usable"
        case .failed:
            return "failed row"
        case .expired:
            if row.claimToken != nil {
                if let leaseExpiresAt = row.leaseExpiresAt, leaseExpiresAt > dateProvider.now() {
                    return "active cleanup claim"
                }

                return "cleanup claim present"
            }

            return "expired row"
        }
    }

    func recoveryMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        queueName: String,
        recoveryReason: String? = nil,
        error: (any Error)? = nil
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, source: source, idxURL: idxURL, idxProbe: idxProbe)
        metadata["queue"] = .string(queueName)
        metadata["status"] = .string(PressureArtifactCatalogStatus.pending.rawValue)
        metadata["queueReason"] = .string("warm enqueue")
        if let recoveryReason {
            metadata["recoveryReason"] = .string(recoveryReason)
        }
        if let error {
            metadata["error"] = .string(String(reflecting: error))
        }
        return metadata
    }

    func makeUnavailableSummary(idxURL: URL, idxProbe: HrrrRemoteObjectProbeResult) -> String {
        let status = idxProbe.status.map(String.init) ?? "unknown"
        return "IDX unavailable for \(idxURL.absoluteString) (status: \(status))"
    }

    func skipMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        catalogStatus: String? = nil,
        reason: String
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, source: source, idxURL: idxURL, idxProbe: idxProbe)
        metadata["catalogSkipReason"] = .string(reason)
        if let catalogStatus {
            metadata["status"] = .string(catalogStatus)
        }
        return metadata
    }

    func enqueueMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        queueName: String,
        error: (any Error)? = nil
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, source: source, idxURL: idxURL, idxProbe: idxProbe)
        metadata["queue"] = .string(queueName)
        metadata["status"] = .string(PressureArtifactCatalogStatus.pending.rawValue)
        metadata["queueReason"] = .string("warm enqueue")
        if let error {
            metadata["error"] = .string(String(reflecting: error))
        }
        return metadata
    }

    func unavailabilityMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, source: source, idxURL: idxURL, idxProbe: idxProbe)
        metadata["status"] = .string(PressureArtifactCatalogStatus.failed.rawValue)
        metadata["catalogSkipReason"] = .string("idx unavailable")
        return metadata
    }

    func baseMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult
    ) -> Logger.Metadata {
        [
            "source": .string(source.sourceKind.rawValue),
            "runTime": .string(candidate.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(candidate.forecastHour),
            "validTime": .string(candidate.validTime.ISO8601Format()),
            "product": .string(candidate.product.rawValue),
            "fieldSetVersion": .string(candidate.fieldSetVersion.rawValue),
            "idxURL": .string(idxURL.absoluteString),
            "idxStatus": .string(idxProbe.status.map(String.init) ?? "unknown"),
            "idxAvailable": .stringConvertible(idxProbe.available)
        ]
    }

    func candidateMetadata(
        for candidate: HrrrRunCandidate,
        source: StormSetupSourceMetadata,
        idxURL: URL? = nil,
        idxProbe: HrrrRemoteObjectProbeResult? = nil,
        extra: [String: Logger.MetadataValue] = [:]
    ) -> Logger.Metadata {
        var metadata: Logger.Metadata = [
            "source": .string(source.sourceKind.rawValue),
            "runTime": .string(candidate.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(candidate.forecastHour),
            "validTime": .string(candidate.validTime.ISO8601Format()),
            "product": .string(candidate.product.rawValue),
            "fieldSetVersion": .string(candidate.fieldSetVersion.rawValue)
        ]

        if let idxURL {
            metadata["idxURL"] = .string(idxURL.absoluteString)
        }

        if let idxProbe {
            metadata["idxStatus"] = .string(idxProbe.status.map(String.init) ?? "unknown")
            metadata["idxAvailable"] = .stringConvertible(idxProbe.available)
        }

        for (key, value) in extra {
            metadata[key] = value
        }
        return metadata
    }
}
