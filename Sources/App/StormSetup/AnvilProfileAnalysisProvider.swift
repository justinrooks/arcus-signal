import Foundation
import Vapor

protocol AnvilProfileAnalysisProviding: Sendable {
    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse
}

enum AnvilProfileAnalysisError: Error, Sendable, CustomStringConvertible {
    case upstreamUnavailable(reason: String)
    case unusableProfile(reason: String)
    case internalExecutionFailure(reason: String)
    case badGateway(reason: String)
    case gatewayTimeout(reason: String)

    var description: String {
        switch self {
        case .upstreamUnavailable(let reason):
            return "Upstream HRRR data was unavailable. \(reason)"
        case .unusableProfile(let reason):
            return "The grouped HRRR profile could not produce a valid Anvil request. \(reason)"
        case .internalExecutionFailure(let reason):
            return "Anvil analysis request assembly failed during internal execution. \(reason)"
        case .badGateway(let reason):
            return "Anvil analysis failed because the upstream response was invalid or unavailable. \(reason)"
        case .gatewayTimeout(let reason):
            return "Anvil analysis timed out waiting for the upstream service. \(reason)"
        }
    }
}

extension AnvilProfileAnalysisError {
    func asAbort() -> Abort {
        switch self {
        case .upstreamUnavailable:
            return Abort(.serviceUnavailable, reason: description)
        case .unusableProfile:
            return Abort(.unprocessableEntity, reason: description)
        case .internalExecutionFailure:
            return Abort(.internalServerError, reason: description)
        case .badGateway:
            return Abort(.badGateway, reason: description)
        case .gatewayTimeout:
            return Abort(.gatewayTimeout, reason: description)
        }
    }
}

struct DefaultAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding {
    private let previewProvider: any AnvilProfilePreviewProviding
    private let configuration: StormSetupConfiguration?
    private let httpClient: (any HTTPClient)?
    private let directClient: (any AnvilProfileClient)?

    init(
        previewProvider: any AnvilProfilePreviewProviding,
        configuration: StormSetupConfiguration,
        httpClient: any HTTPClient
    ) {
        self.previewProvider = previewProvider
        self.configuration = configuration
        self.httpClient = httpClient
        self.directClient = nil
    }

    init(
        previewProvider: any AnvilProfilePreviewProviding,
        anvilClient: any AnvilProfileClient
    ) {
        self.previewProvider = previewProvider
        self.configuration = nil
        self.httpClient = nil
        self.directClient = anvilClient
    }

    init(application: Application) {
        self.init(
            previewProvider: application.anvilProfilePreviewProvider,
            configuration: application.stormSetupConfiguration,
            httpClient: VaporApplicationHTTPClient(application: application)
        )
    }

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        let client: any AnvilProfileClient
        if let directClient {
            client = directClient
        } else if let configuration, let httpClient {
            do {
                client = try configuration.makeAnvilProfileClient(httpClient: httpClient)
            } catch let error as AnvilProfileClientError {
                throw classify(clientError: error)
            } catch {
                try rethrowCancellationIfNeeded(error)
                throw AnvilProfileAnalysisError.internalExecutionFailure(reason: String(describing: error))
            }
        } else {
            throw AnvilProfileAnalysisError.internalExecutionFailure(reason: "Anvil analysis provider was misconfigured.")
        }

        let preview: AnvilAnalyzeProfilePreviewResponse
        do {
            preview = try await previewProvider.previewProfile(for: h3Cell)
        } catch let error as AnvilProfilePreviewError {
            throw classify(previewError: error)
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfileAnalysisError.internalExecutionFailure(reason: String(describing: error))
        }

        let response: AnvilAnalyzeProfileResponse
        do {
            response = try await client.analyzeProfile(preview.request)
        } catch let error as AnvilProfileClientError {
            throw classify(clientError: error)
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw AnvilProfileAnalysisError.internalExecutionFailure(reason: String(describing: error))
        }

        return AnvilAnalyzeProfileAnalysisResponse(
            request: preview.request,
            debug: preview.debug,
            response: response
        )
    }

    private func classify(previewError: AnvilProfilePreviewError) -> AnvilProfileAnalysisError {
        switch previewError {
        case .upstreamUnavailable(let reason):
            return .upstreamUnavailable(reason: reason)
        case .unusableProfile(let reason):
            return .unusableProfile(reason: reason)
        case .internalExecutionFailure(let reason):
            return .internalExecutionFailure(reason: reason)
        }
    }

    private func classify(clientError: AnvilProfileClientError) -> AnvilProfileAnalysisError {
        switch clientError {
        case .missingConfiguration(let missingKeys):
            return .internalExecutionFailure(reason: "Missing Anvil configuration: \(missingKeys.sorted().joined(separator: ", ")).")
        case .transportFailure(let endpoint, let reason):
            return .badGateway(reason: "\(endpoint.absoluteString): \(reason)")
        case .requestTimedOut(let endpoint, let timeoutSeconds, let reason):
            return .gatewayTimeout(reason: "\(endpoint.absoluteString) timed out after \(timeoutSeconds) seconds. \(reason)")
        case .unexpectedHTTPStatus(let endpoint, let status, let responsePreview):
            if let responsePreview, !responsePreview.isEmpty {
                return .badGateway(reason: "\(endpoint.absoluteString) returned HTTP \(status). Response preview: \(responsePreview)")
            }
            return .badGateway(reason: "\(endpoint.absoluteString) returned HTTP \(status).")
        case .malformedResponseJSON(let endpoint, let reason, let responsePreview):
            if let responsePreview, !responsePreview.isEmpty {
                return .badGateway(reason: "\(endpoint.absoluteString) returned malformed JSON: \(reason). Response preview: \(responsePreview)")
            }
            return .badGateway(reason: "\(endpoint.absoluteString) returned malformed JSON: \(reason)")
        }
    }
}

extension Application {
    var anvilProfileAnalysisProvider: any AnvilProfileAnalysisProviding {
        get {
            storage[AnvilProfileAnalysisProviderKey.self] ?? DefaultAnvilProfileAnalysisProvider(application: self)
        }
        set {
            storage[AnvilProfileAnalysisProviderKey.self] = newValue
        }
    }
}

private struct AnvilProfileAnalysisProviderKey: StorageKey {
    typealias Value = any AnvilProfileAnalysisProviding
}
