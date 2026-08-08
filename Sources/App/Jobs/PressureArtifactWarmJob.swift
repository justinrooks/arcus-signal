import Foundation
import Queues
import Vapor
import ArcusCore

struct PressureArtifactWarmJobPayload: Codable, Sendable {
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let product: HrrrProduct
    let fieldSetVersion: HrrrFieldSetVersion
    let acquisitionAttempt: Int

    init(
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion,
        acquisitionAttempt: Int = 0
    ) {
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.product = product
        self.fieldSetVersion = fieldSetVersion
        self.acquisitionAttempt = max(0, acquisitionAttempt)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            runTime: try container.decode(Date.self, forKey: .runTime),
            forecastHour: try container.decode(Int.self, forKey: .forecastHour),
            validTime: try container.decode(Date.self, forKey: .validTime),
            product: try container.decode(HrrrProduct.self, forKey: .product),
            fieldSetVersion: try container.decode(HrrrFieldSetVersion.self, forKey: .fieldSetVersion),
            acquisitionAttempt: try container.decodeIfPresent(Int.self, forKey: .acquisitionAttempt) ?? 0
        )
    }

    private enum CodingKeys: String, CodingKey {
        case runTime
        case forecastHour
        case validTime
        case product
        case fieldSetVersion
        case acquisitionAttempt
    }
}

enum PressureArtifactWarmJobError: Error, Sendable, CustomStringConvertible {
    case retryDispatchFailed(errorType: String)
    case warmingFailed(errorType: String)

    var description: String {
        switch self {
        case .retryDispatchFailed(let errorType):
            return "Pressure artifact acquisition retry dispatch failed (\(errorType))."
        case .warmingFailed(let errorType):
            return "Pressure artifact warming failed (\(errorType))."
        }
    }
}

struct PressureArtifactWarmRetryContinuation: Sendable {
    let payload: PressureArtifactWarmJobPayload
    let delaySeconds: Int
}

enum PressureArtifactWarmRetryPolicy {
    static let maximumAcquisitionAttempts = 3
    private static let delaysSeconds = [30, 120]

    static func continuation(
        after payload: PressureArtifactWarmJobPayload
    ) -> PressureArtifactWarmRetryContinuation? {
        guard payload.acquisitionAttempt < delaysSeconds.count else {
            return nil
        }

        return PressureArtifactWarmRetryContinuation(
            payload: PressureArtifactWarmJobPayload(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                validTime: payload.validTime,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                acquisitionAttempt: payload.acquisitionAttempt + 1
            ),
            delaySeconds: delaysSeconds[payload.acquisitionAttempt]
        )
    }

    static func isTransientAcquisitionFailure(_ error: any Error) -> Bool {
        guard !(error is CancellationError) else {
            return false
        }

        if let acquisitionError = error as? PressureArtifactAcquisitionError {
            if case .transient = acquisitionError {
                return true
            }
            return false
        }

        if let warmingError = error as? PressureArtifactWarmingError {
            if case .warmAttemptTimedOut = warmingError {
                return true
            }
            return false
        }

        if error is HrrrPressureByteRangeDownloaderError
            || error is HrrrPressureSubsetGribCacheError
            || error is HrrrPressureSubsetGribCacheKeyError
            || error is PressureArtifactValidationError
            || error is Abort {
            return false
        }

        return false
    }
}

protocol PressureArtifactWarmRetryDispatching: Sendable {
    func dispatch(
        _ continuation: PressureArtifactWarmRetryContinuation,
        on application: Application
    ) async throws
}

struct DefaultPressureArtifactWarmRetryDispatcher: PressureArtifactWarmRetryDispatching {
    func dispatch(
        _ continuation: PressureArtifactWarmRetryContinuation,
        on application: Application
    ) async throws {
        try await application.queues
            .queue(ArcusQueueLane.modelArtifacts.queueName)
            .dispatch(
                PressureArtifactWarmJob.self,
                continuation.payload,
                maxRetryCount: 0,
                delayUntil: Date(timeIntervalSinceNow: TimeInterval(continuation.delaySeconds))
            )
    }
}

enum PressureArtifactAcquisitionError: Error, Sendable, CustomStringConvertible {
    case transient(String)
    case terminal(String)

    static func classify(_ error: any Error) -> Self {
        let description = String(describing: error)
        if HTTPTransportFailureClassifier.isTransient(error)
            || recognizedPressureRequestErrorTokens.contains(where: description.lowercased().contains) {
            return .transient(description)
        }
        return .terminal(description)
    }

    var description: String {
        switch self {
        case .transient(let reason):
            return "Transient pressure artifact acquisition failure: \(reason)"
        case .terminal(let reason):
            return "Terminal pressure artifact acquisition failure: \(reason)"
        }
    }

    private static let recognizedPressureRequestErrorTokens = [
        "httpclienterror.readtimeout",
        "httpclienterror.writetimeout",
        "httpclienterror.connecttimeout",
        "httpclienterror.sockshandshaketimeout",
        "httpclienterror.httpproxyhandshaketimeout",
        "httpclienterror.tlshandshaketimeout",
        "httpclienterror.getconnectionfrompooltimeout",
        "httpclienterror.deadlineexceeded",
        "httpclienterror.remoteconnectionclosed",
        "channelerror.connecttimeout"
    ]
}

struct PressureArtifactWarmJob: AsyncJob {
    typealias Payload = PressureArtifactWarmJobPayload

    private let makeWarmingService: @Sendable (Application) -> any PressureArtifactWarming
    private let retryDispatcher: any PressureArtifactWarmRetryDispatching

    init(
        retryDispatcher: any PressureArtifactWarmRetryDispatching = DefaultPressureArtifactWarmRetryDispatcher(),
        makeWarmingService: @escaping @Sendable (Application) -> any PressureArtifactWarming = { application in
            PressureArtifactWarmingService.makeDefault(application: application)
        }
    ) {
        self.retryDispatcher = retryDispatcher
        self.makeWarmingService = makeWarmingService
    }

    init(
        warmingService: any PressureArtifactWarming,
        retryDispatcher: any PressureArtifactWarmRetryDispatching = DefaultPressureArtifactWarmRetryDispatcher()
    ) {
        self.init(retryDispatcher: retryDispatcher) { _ in warmingService }
    }

    func dequeue(_ context: QueueContext, _ payload: Payload) async throws {
        context.logger.info(
            "PressureArtifactWarmJob started.",
            metadata: [
                "runTime": .string(payload.runTime.ISO8601Format()),
                "forecastHour": .stringConvertible(payload.forecastHour),
                "validTime": .string(payload.validTime.ISO8601Format()),
                "product": .string(payload.product.rawValue),
                "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
            ]
        )

        let warmingService = makeWarmingService(context.application)
        do {
            try await warmingService.warm(
                payload: payload,
                on: context.application,
                logger: context.logger
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            if PressureArtifactWarmRetryPolicy.isTransientAcquisitionFailure(error) {
                try await scheduleRetryIfAvailable(
                    after: error,
                    payload: payload,
                    context: context
                )
                return
            }
            if let disposition = error as? PressureArtifactFailureDispositionError {
                context.logger.error(
                    "\(disposition.logMessage)",
                    metadata: artifactMetadata(payload).merging([
                        "acquisitionAttempt": .stringConvertible(payload.acquisitionAttempt),
                        "errorType": .string(disposition.errorType)
                    ]) { _, new in new }
                )
                return
            }
            if error is PressureArtifactFailureCompletionError {
                throw PressureArtifactWarmJobError.warmingFailed(
                    errorType: String(describing: type(of: error))
                )
            }

            context.logger.error(
                "PressureArtifactWarmJob completed with a terminal failure.",
                metadata: artifactMetadata(payload)
            )
            return
        }

        context.logger.info(
            "PressureArtifactWarmJob finished.",
            metadata: artifactMetadata(payload)
        )
    }

    func error(_ context: QueueContext, _ error: any Error, _ payload: Payload) async throws {
        context.logger.error(
            "PressureArtifactWarmJob failed.",
            metadata: [
                "runTime": .string(payload.runTime.ISO8601Format()),
                "forecastHour": .stringConvertible(payload.forecastHour),
                "validTime": .string(payload.validTime.ISO8601Format()),
                "product": .string(payload.product.rawValue),
                "fieldSetVersion": .string(payload.fieldSetVersion.rawValue),
                "errorType": .string(String(describing: type(of: error)))
            ]
        )
    }

    private func scheduleRetryIfAvailable(
        after error: any Error,
        payload: Payload,
        context: QueueContext
    ) async throws {
        guard let continuation = PressureArtifactWarmRetryPolicy.continuation(after: payload) else {
            context.logger.error(
                "PressureArtifactWarmJob exhausted transient acquisition attempts.",
                metadata: artifactMetadata(payload).merging([
                    "acquisitionAttempt": .stringConvertible(payload.acquisitionAttempt),
                    "errorType": .string(String(describing: type(of: error)))
                ]) { _, new in new }
            )
            return
        }

        do {
            try await retryDispatcher.dispatch(
                continuation,
                on: context.application
            )
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw PressureArtifactWarmJobError.retryDispatchFailed(
                errorType: String(describing: type(of: error))
            )
        }

        context.logger.info(
            "PressureArtifactWarmJob scheduled a transient acquisition retry.",
            metadata: artifactMetadata(payload).merging([
                "acquisitionAttempt": .stringConvertible(payload.acquisitionAttempt),
                "nextAcquisitionAttempt": .stringConvertible(continuation.payload.acquisitionAttempt),
                "retryDelaySeconds": .stringConvertible(continuation.delaySeconds)
            ]) { _, new in new }
        )
    }

    private func artifactMetadata(_ payload: Payload) -> Logger.Metadata {
        [
            "runTime": .string(payload.runTime.ISO8601Format()),
            "forecastHour": .stringConvertible(payload.forecastHour),
            "validTime": .string(payload.validTime.ISO8601Format()),
            "product": .string(payload.product.rawValue),
            "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
        ]
    }
}
