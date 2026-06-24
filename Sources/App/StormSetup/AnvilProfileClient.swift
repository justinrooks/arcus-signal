import Foundation

protocol AnvilProfileClient: Sendable {
    func analyzeProfile(_ request: AnvilAnalyzeProfileRequest) async throws -> AnvilAnalyzeProfileResponse
}

enum AnvilProfileClientError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingConfiguration(missingKeys: [String])
    case transportFailure(endpoint: URL, reason: String)
    case requestTimedOut(endpoint: URL, timeoutSeconds: TimeInterval, reason: String)
    case unexpectedHTTPStatus(endpoint: URL, status: Int, responsePreview: String?)
    case malformedResponseJSON(endpoint: URL, reason: String, responsePreview: String?)

    var description: String {
        switch self {
        case .missingConfiguration(let missingKeys):
            return "Missing Anvil profile-analysis configuration: \(missingKeys.sorted().joined(separator: ", "))."
        case .transportFailure(let endpoint, let reason):
            return "Anvil profile-analysis request failed for \(endpoint.absoluteString): \(reason)"
        case .requestTimedOut(let endpoint, let timeoutSeconds, let reason):
            return "Anvil profile-analysis request timed out after \(timeoutSeconds) seconds for \(endpoint.absoluteString): \(reason)"
        case .unexpectedHTTPStatus(let endpoint, let status, let responsePreview):
            if let responsePreview, !responsePreview.isEmpty {
                return "Anvil profile-analysis returned HTTP \(status) for \(endpoint.absoluteString). Response preview: \(responsePreview)"
            }
            return "Anvil profile-analysis returned HTTP \(status) for \(endpoint.absoluteString)."
        case .malformedResponseJSON(let endpoint, let reason, let responsePreview):
            if let responsePreview, !responsePreview.isEmpty {
                return "Anvil profile-analysis returned malformed JSON for \(endpoint.absoluteString): \(reason). Response preview: \(responsePreview)"
            }
            return "Anvil profile-analysis returned malformed JSON for \(endpoint.absoluteString): \(reason)"
        }
    }
}

struct DefaultAnvilProfileClient: AnvilProfileClient, Sendable {
    private static let profileAnalysisPathComponents = ["v1", "analyze-profile"]

    private let httpClient: any HTTPClient
    private let endpointURL: URL
    private let timeoutSeconds: TimeInterval
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init(
        baseURL: URL,
        timeoutSeconds: TimeInterval,
        httpClient: any HTTPClient
    ) {
        self.httpClient = httpClient
        self.endpointURL = Self.makeEndpointURL(from: baseURL)
        self.timeoutSeconds = timeoutSeconds

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder
    }

    func analyzeProfile(_ request: AnvilAnalyzeProfileRequest) async throws -> AnvilAnalyzeProfileResponse {
        let body = try jsonEncoder.encode(request)
        let response: HTTPResponse

        do {
            response = try await httpClient.post(
                endpointURL,
                headers: requestHeaders,
                body: body,
                timeoutSeconds: timeoutSeconds
            )
        } catch let error as URLError where error.code == .timedOut {
            throw AnvilProfileClientError.requestTimedOut(
                endpoint: endpointURL,
                timeoutSeconds: timeoutSeconds,
                reason: String(describing: error)
            )
        } catch {
            if isTimeout(error) {
                throw AnvilProfileClientError.requestTimedOut(
                    endpoint: endpointURL,
                    timeoutSeconds: timeoutSeconds,
                    reason: String(describing: error)
                )
            }

            throw AnvilProfileClientError.transportFailure(
                endpoint: endpointURL,
                reason: String(describing: error)
            )
        }

        guard (200...299).contains(response.status) else {
            throw AnvilProfileClientError.unexpectedHTTPStatus(
                endpoint: endpointURL,
                status: response.status,
                responsePreview: responsePreview(from: response)
            )
        }

        guard let data = response.data, !data.isEmpty else {
            throw AnvilProfileClientError.malformedResponseJSON(
                endpoint: endpointURL,
                reason: "Response body was empty.",
                responsePreview: nil
            )
        }

        do {
            return try jsonDecoder.decode(AnvilAnalyzeProfileResponse.self, from: data)
        } catch {
            throw AnvilProfileClientError.malformedResponseJSON(
                endpoint: endpointURL,
                reason: String(describing: error),
                responsePreview: bodyPreview(from: data)
            )
        }
    }

    private var requestHeaders: [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/json"
        ]
    }

    private static func makeEndpointURL(from baseURL: URL) -> URL {
        profileAnalysisPathComponents.reduce(baseURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: false)
        }
    }

    private func responsePreview(from response: HTTPResponse) -> String? {
        guard let data = response.data, !data.isEmpty else {
            return nil
        }

        return bodyPreview(from: data)
    }

    private func bodyPreview(from data: Data) -> String {
        let text = String(data: data.prefix(256), encoding: .utf8) ?? "<binary>"
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isTimeout(_ error: any Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }

        let message = String(describing: error).lowercased()
        return message.contains("timed out")
    }
}
