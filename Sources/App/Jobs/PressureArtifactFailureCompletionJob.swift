import Foundation
import Queues
import Vapor

struct PressureArtifactFailureCompletionJobPayload: Codable, Sendable {
    let artifact: PressureArtifactWarmJobPayload
    let claimToken: UUID
    let errorSummary: String
}

struct PressureArtifactFailureCompletionRetryPolicy: Sendable, Equatable {
    static let defaultDelaysSeconds = [15, 60, 300]

    let delaysSeconds: [Int]

    init(delaysSeconds: [Int] = defaultDelaysSeconds) {
        self.delaysSeconds = delaysSeconds.isEmpty
            || delaysSeconds.count > Self.defaultDelaysSeconds.count
            || delaysSeconds.contains(where: { $0 <= 0 })
            ? Self.defaultDelaysSeconds
            : delaysSeconds
    }

    var maximumRetryCount: Int { delaysSeconds.count }

    func delaySeconds(forAttempt attempt: Int) -> Int {
        let index = min(max(0, attempt - 1), delaysSeconds.count - 1)
        return delaysSeconds[index]
    }
}

protocol PressureArtifactFailureCompletionJobDispatching: Sendable {
    func dispatch(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws
}

struct DefaultPressureArtifactFailureCompletionJobDispatcher: PressureArtifactFailureCompletionJobDispatching {
    func dispatch(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws {
        let retryPolicy = application.stormSetupConfiguration
            .pressureArtifactFailureCompletionRetryPolicy
        try await application.queues
            .queue(ArcusQueueLane.modelArtifacts.queueName)
            .dispatch(
                PressureArtifactFailureCompletionJob.self,
                payload,
                maxRetryCount: retryPolicy.maximumRetryCount
            )
    }
}

protocol PressureArtifactFailureCompleting: Sendable {
    func complete(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws -> Bool
}

struct DefaultPressureArtifactFailureCompleter: PressureArtifactFailureCompleting {
    private let catalogStore: PressureArtifactCatalogStore

    init(catalogStore: PressureArtifactCatalogStore = PressureArtifactCatalogStore()) {
        self.catalogStore = catalogStore
    }

    func complete(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws -> Bool {
        try Task.checkCancellation()

        do {
            return try await catalogStore.markFailed(
                payload: payload.artifact,
                claimToken: payload.claimToken,
                errorSummary: payload.errorSummary,
                on: application.db
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw PressureArtifactFailureCompletionError.persistenceFailed(
                errorType: String(describing: type(of: error))
            )
        }
    }
}

enum PressureArtifactFailureCompletionError: Error, Sendable, CustomStringConvertible {
    case persistenceFailed(errorType: String)
    case dispatchFailed(errorType: String)

    var description: String {
        switch self {
        case .persistenceFailed(let errorType):
            return "Pressure artifact failure completion persistence failed (\(errorType))."
        case .dispatchFailed(let errorType):
            return "Pressure artifact failure completion dispatch failed (\(errorType))."
        }
    }
}

struct PressureArtifactFailureCompletionJob: AsyncJob {
    typealias Payload = PressureArtifactFailureCompletionJobPayload

    private let makeCompleter: @Sendable (Application) -> any PressureArtifactFailureCompleting
    private let retryPolicy: PressureArtifactFailureCompletionRetryPolicy

    init(
        retryPolicy: PressureArtifactFailureCompletionRetryPolicy = .init(),
        makeCompleter: @escaping @Sendable (Application) -> any PressureArtifactFailureCompleting = { _ in
            DefaultPressureArtifactFailureCompleter()
        }
    ) {
        self.retryPolicy = retryPolicy
        self.makeCompleter = makeCompleter
    }

    init(
        completer: any PressureArtifactFailureCompleting,
        retryPolicy: PressureArtifactFailureCompletionRetryPolicy = .init()
    ) {
        self.init(retryPolicy: retryPolicy) { _ in completer }
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        try Task.checkCancellation()
        let completed = try await makeCompleter(context.application).complete(
            payload,
            on: context.application
        )

        context.logger.info(
            completed
                ? "Pressure artifact failure completion succeeded."
                : "Pressure artifact failure completion was already obsolete.",
            metadata: artifactMetadata(payload.artifact)
        )
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "Pressure artifact failure completion exhausted retries.",
            metadata: artifactMetadata(payload.artifact).merging([
                "errorType": .string(String(describing: type(of: error)))
            ]) { _, new in new }
        )
    }

    func nextRetryIn(attempt: Int) -> Int {
        retryPolicy.delaySeconds(forAttempt: attempt)
    }

    private func artifactMetadata(_ payload: PressureArtifactWarmJobPayload) -> Logger.Metadata {
        [
            "runTime": .string(payload.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(payload.forecastHour),
            "validTime": .string(payload.validTime.ISO8601Format()),
            "product": .string(payload.product.rawValue),
            "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
        ]
    }
}

enum PressureArtifactFailureSummary {
    static let maximumLength = 512

    static func sanitized(from error: any Error, claimToken: UUID) -> String {
        let tokenValues = [claimToken.uuidString, claimToken.uuidString.lowercased()]
        var summary = String(reflecting: error)
        for token in tokenValues {
            summary = summary.replacingOccurrences(of: token, with: "[redacted-token]")
        }

        summary = summary
            .split(whereSeparator: \Character.isWhitespace)
            .map { component in
                let value = String(component)
                if value.contains("://") || value.contains("/") {
                    return "[redacted-location]"
                }
                return value
            }
            .joined(separator: " ")

        if summary.isEmpty {
            summary = String(describing: type(of: error))
        }

        return String(summary.prefix(maximumLength))
    }
}
