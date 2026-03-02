import Foundation
import Vapor

public enum HTTPStatusClassification: Sendable, Equatable {
    case success
    case rateLimited(retryAfterSeconds: Int?)
    case serviceUnavailable(retryAfterSeconds: Int?)
    case failure(status: Int)
}

public enum HTTPRetryAfterParser {
    public static func seconds(from value: String?, now: Date = .now) -> Int? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let seconds = Int(value) {
            return max(0, seconds)
        }

        let retryAt = value.fromRFC1123String() ?? value.fromRFC822()
        guard let retryAt else { return nil }

        return max(0, Int(ceil(retryAt.timeIntervalSince(now))))
    }
}

public enum HTTPRequestHeaders {
    public static func userAgent(bundle: Bundle = .main, fallbackName: String = "arcus-signal") -> String {
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? fallbackName
        let appVersion = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        let build = (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
        let bundleID = bundle.bundleIdentifier ?? "arcus.signal"
        return "\(appName)/\(appVersion) (\(bundleID); build:\(build))"
    }

    public static func nws(bundle: Bundle = .main) -> [String: String] {
        [
            "User-Agent": userAgent(bundle: bundle),
            "Accept": "application/geo+json"
        ]
    }

    public static func spcRss(bundle: Bundle = .main) -> [String: String] {
        [
            "User-Agent": userAgent(bundle: bundle),
            "Accept": "application/rss+xml, application/xml;q=0.9, */*;q=0.8"
        ]
    }

    public static func spcGeoJSON(bundle: Bundle = .main) -> [String: String] {
        [
            "User-Agent": userAgent(bundle: bundle),
            "Accept": "application/geo+json, application/json;q=0.9, */*;q=0.8"
        ]
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let headers: [String: String]
    public let data: Data?

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func classifyStatus(now: Date = .now) -> HTTPStatusClassification {
        guard !(200...299).contains(status) else { return .success }

        let retryAfter = HTTPRetryAfterParser.seconds(from: header("Retry-After"), now: now)
        switch status {
        case 429:
            return .rateLimited(retryAfterSeconds: retryAfter)
        case 503:
            return .serviceUnavailable(retryAfterSeconds: retryAfter)
        default:
            return .failure(status: status)
        }
    }
}

public protocol HTTPResponseObserving: Sendable {
    func didReceive(response: HTTPResponse, for requestURL: URL) async
}

public struct NoOpHTTPResponseObserver: HTTPResponseObserving {
    public init() {}
    public func didReceive(response: HTTPResponse, for requestURL: URL) async {}
}

public actor LastGlobalSuccessHTTPObserver: HTTPResponseObserving {
    public private(set) var lastGlobalSuccessAt: Date?

    public init() {}

    public func didReceive(response: HTTPResponse, for requestURL: URL) async {
        guard (200...299).contains(response.status) else { return }
        if let lastModified = response.header("Last-Modified")?.fromRFC1123String() {
            lastGlobalSuccessAt = lastModified
            return
        }
        lastGlobalSuccessAt = .now
    }
}

public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
    func clearCache()
}

public final class VaporApplicationHTTPClient: HTTPClient {
    private let application: Application
    private let delays: [UInt64]
    private let observer: any HTTPResponseObserving
    private let logger: Logger

    public init(
        application: Application,
        observer: any HTTPResponseObserving = NoOpHTTPResponseObserver(),
        retryDelaysSeconds: [UInt64] = [0, 5, 10, 15]
    ) {
        self.application = application
        self.observer = observer
        self.delays = retryDelaysSeconds
        self.logger = .networkDownloader
    }

    public func get(_ url: URL, headers: [String: String] = [:]) async throws -> HTTPResponse {
        try await request(url: url, method: .GET, headers: headers)
    }

    /// Vapor's client does not expose an app-level HTTP cache to clear.
    public func clearCache() {}

    private func request(
        url: URL,
        method: HTTPMethod,
        headers: [String: String]
    ) async throws -> HTTPResponse {
        let retryDelays = delays.isEmpty ? [0] : delays

        for attempt in 0..<retryDelays.count {
            try Task.checkCancellation()
            do {
                let uri = URI(string: url.absoluteString)
                let response = try await application.client.send(
                    method,
                    headers: vaporHeaders(from: headers),
                    to: uri
                )

                let normalized = toHTTPResponse(response)
                await observer.didReceive(response: normalized, for: url)
                return normalized
            } catch {
                if error is CancellationError || Task.isCancelled {
                    logger.debug(
                        "HTTP request cancelled.",
                        metadata: [
                            "host": .string(url.host ?? "unknown"),
                            "path": .string(url.path)
                        ]
                    )
                    throw CancellationError()
                }

                if isTransient(error), attempt < retryDelays.count - 1 {
                    let wait = retryDelays[attempt + 1]
                    logger.debug(
                        "Retrying transient HTTP failure.",
                        metadata: [
                            "host": .string(url.host ?? "unknown"),
                            "path": .string(url.path),
                            "attempt": .string("\(attempt + 1)"),
                            "waitSeconds": .string("\(wait)")
                        ]
                    )
                    try await Task.sleep(for: .seconds(Int(wait)))
                    continue
                }

                throw error
            }
        }

        throw Abort(.internalServerError, reason: "Unexpected HTTP retry state reached.")
    }

    private func vaporHeaders(from input: [String: String]) -> HTTPHeaders {
        var headers = HTTPHeaders()
        for (key, value) in input {
            headers.add(name: key, value: value)
        }
        return headers
    }

    private func toHTTPResponse(_ response: ClientResponse) -> HTTPResponse {
        let headers = normalizedHeaders(from: response.headers)

        let data: Data?
        if var body = response.body, body.readableBytes > 0 {
            data = body.readData(length: body.readableBytes)
        } else {
            data = nil
        }

        return HTTPResponse(status: Int(response.status.code), headers: headers, data: data)
    }

    private func normalizedHeaders(from headers: HTTPHeaders) -> [String: String] {
        var output: [String: String] = [:]
        output.reserveCapacity(headers.count)

        for header in headers {
            output[header.name] = header.value
        }

        return output
    }

    private func isTransient(_ error: any Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost,
                 .dnsLookupFailed,
                 .resourceUnavailable,
                 .notConnectedToInternet,
                 .internationalRoamingOff,
                 .callIsActive,
                 .dataNotAllowed,
                 .requestBodyStreamExhausted:
                return true
            default:
                break
            }
        }

        let message = String(describing: error).lowercased()
        let transientTokens = [
            "timed out",
            "connection reset",
            "connection refused",
            "temporarily unavailable",
            "network is unreachable",
            "broken pipe",
            "dns"
        ]
        return transientTokens.contains { message.contains($0) }
    }
}
