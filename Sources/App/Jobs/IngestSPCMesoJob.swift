import Fluent
import Foundation
import Queues
import Vapor
import ArcusCore

typealias SPCMesoPersistOperation = @Sendable (
    [MesoscaleDiscussionPayload], any Database, Date
) async throws -> SPCMesoPersistResult

public struct IngestSPCMesoPayload: Codable, Sendable {
    public let runLabel: String?

    public init(runLabel: String? = nil) {
        self.runLabel = runLabel
    }
}

public struct IngestSPCMesoJob: AsyncJob {
    public typealias Payload = IngestSPCMesoPayload
    private let persist: SPCMesoPersistOperation?

    public init() {
        persist = nil
    }

    init(persist: @escaping SPCMesoPersistOperation) {
        self.persist = persist
    }

    public func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        let startedAt = Date()
        var stage = "fetch"
        context.logger.info("IngestSPCMesoJob started.")
        do {
            let products: [MesoscaleDiscussionPayload]
            do {
                products = try await context.application.spcMesoClient.fetchDiscussions()
            } catch {
                stage = isParseRejection(error) ? "parse_reject" : "fetch"
                throw error
            }
            context.logger.info("SPC meso feed accepted by parser.", metadata: [
                "productCount": .stringConvertible(products.count)
            ])

            stage = "persistence"
            let result: SPCMesoPersistResult
            if let persist {
                result = try await persist(products, context.application.db, startedAt)
            } else {
                result = try await SPCMesoIngestPersistence().persist(products, on: context.application.db, seenAt: startedAt,
                    enqueueNotifications: context.application.mesoNotificationsEnabled)
            }
            context.logger.info("SPC meso products persisted.", metadata: [
                "inserted": .stringConvertible(result.inserted),
                "updated": .stringConvertible(result.updated),
                "unchanged": .stringConvertible(result.unchanged),
                "ignored": .stringConvertible(result.ignored)
            ])
            stage = "notification_handoff"
            try await MesoNotificationOutboxStore().dispatchPending(context: context)
            await recordRun(
                context: context,
                status: .succeeded,
                startedAt: startedAt,
                completedAt: Date(),
                productCount: products.count,
                runLabel: payload.runLabel,
                errorMessage: nil
            )
            context.logger.info("IngestSPCMesoJob finished.")
        } catch {
            if stage == "persistence" {
                if isParseRejection(error) {
                    stage = "parse_reject"
                } else if isCoverageFailure(error) {
                    stage = "h3"
                }
            }
            let message = "stage=\(stage) error=\(String(reflecting: error))"
            await recordRun(
                context: context,
                status: .failed,
                startedAt: startedAt,
                completedAt: Date(),
                productCount: nil,
                runLabel: payload.runLabel,
                errorMessage: message
            )
            context.logger.error("IngestSPCMesoJob failed.", metadata: [
                "stage": .string(stage),
                "error": .string(String(reflecting: error))
            ])
            throw error
        }
    }

    public func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error("IngestSPCMesoJob exhausted queue execution.", metadata: [
            "error": .string(String(reflecting: error))
        ])
    }

    private func isParseRejection(_ error: any Error) -> Bool {
        guard let error = error as? SPCMesoError else { return false }
        return switch error {
        case .malformedFeed, .malformedDiscussion: true
        case .upstreamStatus, .missingData: false
        }
    }

    private func isCoverageFailure(_ error: any Error) -> Bool {
        guard let abort = error as? Abort else { return false }
        return abort.reason.contains("SPC meso H3 coverage failed")
    }

    private func recordRun(
        context: QueueContext,
        status: IngestSweepRunStatus,
        startedAt: Date,
        completedAt: Date,
        productCount: Int?,
        runLabel: String?,
        errorMessage: String?
    ) async {
        do {
            try await IngestSweepRunModel(
                source: "spc-meso",
                runLabel: runLabel,
                status: status,
                startedAt: startedAt,
                completedAt: completedAt,
                eventCount: productCount,
                errorMessage: errorMessage
            ).create(on: context.application.db)
        } catch {
            context.logger.warning("Failed to record SPC meso ingest run.", metadata: [
                "status": .string(status.rawValue),
                "error": .string(String(reflecting: error))
            ])
        }
    }
}
