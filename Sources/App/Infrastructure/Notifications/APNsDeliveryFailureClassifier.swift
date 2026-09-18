import APNSCore
import Foundation

enum APNsDeliveryFailureDisposition: Equatable, Sendable {
    case retryable(code: String)
    case terminal(code: String)
    case invalidToken(code: String)
}

struct APNsDeliveryFailureClassifier: Sendable {
    static let transportErrorCode = "TransportError"

    func classify(_ error: any Error) -> APNsDeliveryFailureDisposition {
        guard let apnsError = error as? APNSError else {
            return .retryable(code: Self.transportErrorCode)
        }

        let code = apnsError.reason?.reason ?? "HTTP\(apnsError.responseStatus)"

        if let reason = apnsError.reason,
           Self.invalidTokenReasons.contains(reason) {
            return .invalidToken(code: code)
        }

        if apnsError.responseStatus == 410 {
            return .invalidToken(code: code)
        }

        if let reason = apnsError.reason,
           Self.retryableReasons.contains(reason) {
            return .retryable(code: code)
        }

        if apnsError.responseStatus == 429 || (500...599).contains(apnsError.responseStatus) {
            return .retryable(code: code)
        }

        return .terminal(code: code)
    }

    private static let invalidTokenReasons: Set<APNSError.ErrorReason> = [
        .badDeviceToken,
        .deviceTokenNotForTopic,
        .expiredToken,
        .unregistered
    ]

    private static let retryableReasons: Set<APNSError.ErrorReason> = [
        .idleTimeout,
        .tooManyRequests,
        .internalServerError,
        .serviceUnavailable,
        .shutdown
    ]
}
