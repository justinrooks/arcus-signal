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

    init(
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion
    ) {
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.product = product
        self.fieldSetVersion = fieldSetVersion
    }
}

enum PressureArtifactWarmJobError: Error, Sendable, CustomStringConvertible {
    case warmAttemptTimedOut(seconds: TimeInterval)
    case warmingFailed(errorType: String)

    var description: String {
        switch self {
        case .warmAttemptTimedOut(let seconds):
            return PressureArtifactWarmingError.warmAttemptTimedOut(seconds: seconds).description
        case .warmingFailed(let errorType):
            return "Pressure artifact warming failed (\(errorType))."
        }
    }
}

struct PressureArtifactWarmJob: AsyncJob {
    typealias Payload = PressureArtifactWarmJobPayload

    private let makeWarmingService: @Sendable (Application) -> any PressureArtifactWarming

    init(
        makeWarmingService: @escaping @Sendable (Application) -> any PressureArtifactWarming = { application in
            PressureArtifactWarmingService.makeDefault(application: application)
        }
    ) {
        self.makeWarmingService = makeWarmingService
    }

    init(warmingService: any PressureArtifactWarming) {
        self.init { _ in warmingService }
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
            if case PressureArtifactWarmingError.warmAttemptTimedOut(let seconds) = error {
                throw PressureArtifactWarmJobError.warmAttemptTimedOut(seconds: seconds)
            }
            throw PressureArtifactWarmJobError.warmingFailed(
                errorType: String(describing: type(of: error))
            )
        }

        context.logger.info(
            "PressureArtifactWarmJob finished.",
            metadata: [
                "runTime": .string(payload.runTime.ISO8601Format()),
                "forecastHour": .stringConvertible(payload.forecastHour),
                "validTime": .string(payload.validTime.ISO8601Format()),
                "product": .string(payload.product.rawValue),
                "fieldSetVersion": .string(payload.fieldSetVersion.rawValue)
            ]
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
}
