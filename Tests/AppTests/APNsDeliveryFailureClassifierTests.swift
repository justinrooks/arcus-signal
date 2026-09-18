@testable import App
import APNSCore
import Foundation
import Testing

@Suite("APNs delivery failure classifier")
struct APNsDeliveryFailureClassifierTests {
    private let classifier = APNsDeliveryFailureClassifier()

    @Test("APNs service failures and unknown transport failures are retryable")
    func retryableFailures() throws {
        #expect(
            classifier.classify(try makeAPNSError(status: 429, reason: "TooManyRequests"))
                == .retryable(code: "TooManyRequests")
        )
        #expect(
            classifier.classify(try makeAPNSError(status: 503, reason: "ServiceUnavailable"))
                == .retryable(code: "ServiceUnavailable")
        )
        #expect(
            classifier.classify(TransportFailure())
                == .retryable(code: APNsDeliveryFailureClassifier.transportErrorCode)
        )
    }

    @Test("only proven invalid token responses deactivate the endpoint")
    func tokenFailures() throws {
        #expect(
            classifier.classify(try makeAPNSError(status: 400, reason: "BadDeviceToken"))
                == .invalidToken(code: "BadDeviceToken")
        )
        #expect(
            classifier.classify(try makeAPNSError(status: 410, reason: "Unregistered"))
                == .invalidToken(code: "Unregistered")
        )
    }

    @Test("non-token APNs request failures are terminal")
    func terminalFailures() throws {
        #expect(
            classifier.classify(try makeAPNSError(status: 400, reason: "PayloadTooLarge"))
                == .terminal(code: "PayloadTooLarge")
        )
        #expect(
            classifier.classify(try makeAPNSError(status: 403, reason: "InvalidProviderToken"))
                == .terminal(code: "InvalidProviderToken")
        )
    }

    private func makeAPNSError(status: Int, reason: String) throws -> APNSError {
        let response = try JSONDecoder().decode(
            APNSErrorResponse.self,
            from: Data(#"{"reason":"\#(reason)"}"#.utf8)
        )
        return APNSError(responseStatus: status, apnsResponse: response)
    }
}

private struct TransportFailure: Error {}
