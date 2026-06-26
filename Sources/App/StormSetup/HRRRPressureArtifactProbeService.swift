import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor

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
    private let urlBuilder: HrrrPressureDirectObjectURLBuilder

    init(
        runResolver: any HrrrRunResolving = DefaultHrrrRunResolver(),
        remoteObjectChecker: any HrrrRemoteObjectChecking,
        warmJobDispatcher: any PressureArtifactWarmJobDispatching = DefaultPressureArtifactWarmJobDispatcher(),
        urlBuilder: HrrrPressureDirectObjectURLBuilder = HrrrPressureDirectObjectURLBuilder()
    ) {
        self.runResolver = runResolver
        self.remoteObjectChecker = remoteObjectChecker
        self.warmJobDispatcher = warmJobDispatcher
        self.urlBuilder = urlBuilder
    }

    static func makeDefault(application: Application) -> HRRRPressureArtifactProbeService {
        HRRRPressureArtifactProbeService(
            remoteObjectChecker: HTTPHrrrRemoteObjectChecker(
                httpClient: VaporApplicationHTTPClient(application: application)
            )
        )
    }

    func probe(on application: Application, logger: Logger) async throws {
        let resolution = runResolver.resolveRunCandidates()
        logger.info(
            "HRRR pressure artifact probe started.",
            metadata: [
                "targetValidTime": .string(resolution.targetValidTime.ISO8601Format()),
                "candidateCount": .stringConvertible(resolution.candidates.count)
            ]
        )

        for candidate in resolution.candidates {
            let pressureCandidate = makePressureCandidate(from: candidate)
            let source = urlBuilder.makeSourceMetadata(for: pressureCandidate)
            guard let idxURL = source.idxURL else {
                logger.warning(
                    "HRRR pressure artifact probe skipped candidate with missing idx URL.",
                    metadata: [
                        "runTime": .string(pressureCandidate.runTime.ISO8601Format()),
                        "forecastHour": .stringConvertible(pressureCandidate.forecastHour),
                        "product": .string(pressureCandidate.product.rawValue),
                        "fieldSetVersion": .string(pressureCandidate.fieldSetVersion.rawValue)
                    ]
                )
                continue
            }

            let idxProbe = await remoteObjectChecker.probe(url: idxURL)
            let payload = makePayload(from: pressureCandidate)

            if idxProbe.available {
                do {
                    guard try await claimWarmableCatalogRow(for: payload, on: application.db) else {
                        logger.info(
                            "HRRR pressure artifact warm skipped for existing catalog state.",
                            metadata: skipMetadata(
                                for: pressureCandidate,
                                idxURL: idxURL,
                                idxProbe: idxProbe,
                                reason: "catalog state is pending, warming, or ready"
                            )
                        )
                        return
                    }

                    try await warmJobDispatcher.dispatch(
                        payload,
                        to: ArcusQueueLane.modelArtifacts.queueName,
                        on: application
                    )

                    logger.info(
                        "HRRR pressure artifact warm enqueued.",
                        metadata: enqueueMetadata(
                            for: pressureCandidate,
                            idxURL: idxURL,
                            idxProbe: idxProbe,
                            queueName: ArcusQueueLane.modelArtifacts.queueName.string
                        )
                    )
                    return
                } catch {
                    try await markProbeFailure(
                        payload: payload,
                        error: error,
                        on: application.db
                    )
                    logger.error(
                        "HRRR pressure artifact probe failed while enqueueing warm job.",
                        metadata: enqueueMetadata(
                            for: pressureCandidate,
                            idxURL: idxURL,
                            idxProbe: idxProbe,
                            queueName: ArcusQueueLane.modelArtifacts.queueName.string,
                            error: error
                        )
                    )
                    throw error
                }
            }

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
                error_summary
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
                NULL
            )
            ON CONFLICT (run_time, forecast_hour, product, field_set_version)
            DO UPDATE SET
                status = \(bind: PressureArtifactCatalogStatus.pending.rawValue),
                source = \(bind: PressureArtifactCatalogSource.aws.rawValue),
                last_checked_at = NOW(),
                error_summary = NULL,
                local_path = NULL,
                byte_size = NULL
            WHERE pressure_artifact_catalog.status IN (
                \(bind: PressureArtifactCatalogStatus.failed.rawValue),
                \(bind: PressureArtifactCatalogStatus.expired.rawValue)
            )
            RETURNING id
            """)
            .first()

        return row != nil
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
                byte_size = NULL
            WHERE run_time = \(bind: payload.runTime)
              AND forecast_hour = \(bind: payload.forecastHour)
              AND product = \(bind: payload.product.rawValue)
              AND field_set_version = \(bind: payload.fieldSetVersion.rawValue)
            RETURNING id
            """)
            .first()
    }

    func makeUnavailableSummary(idxURL: URL, idxProbe: HrrrRemoteObjectProbeResult) -> String {
        let status = idxProbe.status.map(String.init) ?? "unknown"
        return "IDX unavailable for \(idxURL.absoluteString) (status: \(status))"
    }

    func skipMetadata(
        for candidate: HrrrRunCandidate,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        reason: String
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, idxURL: idxURL, idxProbe: idxProbe)
        metadata["reason"] = .string(reason)
        return metadata
    }

    func enqueueMetadata(
        for candidate: HrrrRunCandidate,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult,
        queueName: String,
        error: (any Error)? = nil
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, idxURL: idxURL, idxProbe: idxProbe)
        metadata["queue"] = .string(queueName)
        if let error {
            metadata["error"] = .string(String(reflecting: error))
        }
        return metadata
    }

    func unavailabilityMetadata(
        for candidate: HrrrRunCandidate,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult
    ) -> Logger.Metadata {
        var metadata = baseMetadata(for: candidate, idxURL: idxURL, idxProbe: idxProbe)
        metadata["reason"] = .string("idx unavailable")
        return metadata
    }

    func baseMetadata(
        for candidate: HrrrRunCandidate,
        idxURL: URL,
        idxProbe: HrrrRemoteObjectProbeResult
    ) -> Logger.Metadata {
        [
            "runTime": .string(candidate.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(candidate.forecastHour),
            "product": .string(candidate.product.rawValue),
            "fieldSetVersion": .string(candidate.fieldSetVersion.rawValue),
            "idxURL": .string(idxURL.absoluteString),
            "idxStatus": .string(idxProbe.status.map(String.init) ?? "unknown"),
            "idxAvailable": .stringConvertible(idxProbe.available)
        ]
    }
}
