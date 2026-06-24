@testable import App
import Foundation
import Testing

@Suite("Anvil profile client", .serialized)
struct AnvilProfileClientTests {
    @Test("missing configuration fails before any request is attempted")
    func missingConfigurationFailsBeforeAnyRequestIsAttempted() async throws {
        let configuration = StormSetupConfiguration.default
        let httpClient = AnvilProfileStubHTTPClient()

        do {
            _ = try configuration.makeAnvilProfileClient(httpClient: httpClient)
            Issue.record("Expected makeAnvilProfileClient to throw when Anvil configuration is missing.")
        } catch let error as AnvilProfileClientError {
            guard case .missingConfiguration(let missingKeys) = error else {
                Issue.record("Expected missingConfiguration, got \(error).")
                return
            }

            #expect(missingKeys.contains("ANVIL_PROFILE_ANALYSIS_BASE_URL"))
            #expect(missingKeys.contains("ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS"))
            #expect(httpClient.requestCount == 0)
        } catch {
            Issue.record("Expected AnvilProfileClientError, got \(error).")
        }
    }

    @Test("client sends the frozen request with the expected method, URL, headers, and JSON body")
    func clientSendsFrozenRequestShape() async throws {
        let request = makeRequest()
        let response = makeResponse(
            status: 200,
            body: try loadFixture(named: "AnvilAnalyzeProfileResponse")
        )
        let httpClient = AnvilProfileStubHTTPClient(plannedResponse: response)
        let configuration = makeConfiguration()
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        _ = try await client.analyzeProfile(request)

        #expect(httpClient.requestCount == 1)

        guard let recorded = httpClient.requests.first else {
            Issue.record("Expected one recorded request.")
            return
        }

        #expect(recorded.method == "POST")
        #expect(recorded.url.absoluteString == "https://anvil.example.com/v1/analyze-profile")
        #expect(recorded.headers["Accept"] == "application/json")
        #expect(recorded.headers["Content-Type"] == "application/json")
        #expect(recorded.timeoutSeconds == 9)
        #expect(recorded.body != nil)

        let decodedRequest = try decoder().decode(AnvilAnalyzeProfileRequest.self, from: recorded.body ?? Data())
        #expect(decodedRequest == request)

        let encodedCanonical = try canonicalJSONString(from: recorded.body ?? Data())
        let requestCanonical = try canonicalJSONString(from: try encoder().encode(request))
        #expect(encodedCanonical == requestCanonical)
    }

    @Test("client decodes the frozen fixture-backed response")
    func clientDecodesFrozenFixtureBackedResponse() async throws {
        let request = makeRequest()
        let responseData = try loadFixture(named: "AnvilAnalyzeProfileResponse")
        let httpClient = AnvilProfileStubHTTPClient(
            plannedResponse: makeResponse(status: 200, body: responseData)
        )
        let configuration = makeConfiguration()
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        let decoded = try await client.analyzeProfile(request)
        let expected = try decoder().decode(AnvilAnalyzeProfileResponse.self, from: responseData)

        #expect(decoded == expected)
    }

    @Test("client maps non-2xx responses with status and response context")
    func clientMapsNon2xxResponsesWithStatusAndResponseContext() async throws {
        let request = makeRequest()
        let body = Data(#"{"error":"upstream offline"}"#.utf8)
        let httpClient = AnvilProfileStubHTTPClient(
            plannedResponse: makeResponse(status: 502, body: body)
        )
        let configuration = makeConfiguration()
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        do {
            _ = try await client.analyzeProfile(request)
            Issue.record("Expected the client to throw for a non-2xx response.")
        } catch let error as AnvilProfileClientError {
            guard case .unexpectedHTTPStatus(let endpoint, let status, let responsePreview) = error else {
                Issue.record("Expected unexpectedHTTPStatus, got \(error).")
                return
            }

            #expect(status == 502)
            #expect(endpoint.absoluteString == "https://anvil.example.com/v1/analyze-profile")
            #expect(responsePreview?.contains("upstream offline") == true)
        } catch {
            Issue.record("Expected AnvilProfileClientError, got \(error).")
        }
    }

    @Test("client maps malformed JSON responses")
    func clientMapsMalformedJSONResponses() async throws {
        let request = makeRequest()
        let httpClient = AnvilProfileStubHTTPClient(
            plannedResponse: makeResponse(status: 200, body: Data(#"{"status":"ok""#.utf8))
        )
        let configuration = makeConfiguration()
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        do {
            _ = try await client.analyzeProfile(request)
            Issue.record("Expected the client to throw for malformed JSON.")
        } catch let error as AnvilProfileClientError {
            guard case .malformedResponseJSON(let endpoint, let reason, let responsePreview) = error else {
                Issue.record("Expected malformedResponseJSON, got \(error).")
                return
            }

            #expect(endpoint.absoluteString == "https://anvil.example.com/v1/analyze-profile")
            #expect(reason.isEmpty == false)
            #expect(responsePreview?.contains(#"{"status":"ok""#) == true)
        } catch {
            Issue.record("Expected AnvilProfileClientError, got \(error).")
        }
    }

    @Test("client maps transport failures")
    func clientMapsTransportFailures() async throws {
        let request = makeRequest()
        let httpClient = AnvilProfileStubHTTPClient(
            plannedError: URLError(.networkConnectionLost)
        )
        let configuration = makeConfiguration()
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        do {
            _ = try await client.analyzeProfile(request)
            Issue.record("Expected the client to throw for a transport failure.")
        } catch let error as AnvilProfileClientError {
            guard case .transportFailure(let endpoint, let reason) = error else {
                Issue.record("Expected transportFailure, got \(error).")
                return
            }

            #expect(endpoint.absoluteString == "https://anvil.example.com/v1/analyze-profile")
            #expect(reason.isEmpty == false)
        } catch {
            Issue.record("Expected AnvilProfileClientError, got \(error).")
        }
    }

    @Test("client maps timeouts when the transport exposes them")
    func clientMapsTimeoutsWhenTheTransportExposesThem() async throws {
        let request = makeRequest()
        let httpClient = AnvilProfileStubHTTPClient(
            plannedError: URLError(.timedOut)
        )
        let configuration = makeConfiguration(timeoutSeconds: 12)
        let client = try configuration.makeAnvilProfileClient(httpClient: httpClient)

        do {
            _ = try await client.analyzeProfile(request)
            Issue.record("Expected the client to throw for a timeout.")
        } catch let error as AnvilProfileClientError {
            guard case .requestTimedOut(let endpoint, let timeoutSeconds, let reason) = error else {
                Issue.record("Expected requestTimedOut, got \(error).")
                return
            }

            #expect(endpoint.absoluteString == "https://anvil.example.com/v1/analyze-profile")
            #expect(timeoutSeconds == 12)
            #expect(reason.isEmpty == false)
        } catch {
            Issue.record("Expected AnvilProfileClientError, got \(error).")
        }
    }

    private func makeConfiguration(timeoutSeconds: TimeInterval = 9) -> StormSetupConfiguration {
        StormSetupConfiguration(
            gribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/grib-subsets"),
            pressureGribSubsetCacheRootURL: URL(fileURLWithPath: "/tmp/pressure-grib-subsets"),
            pressureGribRawCacheRootURL: URL(fileURLWithPath: "/tmp/pressure-grib-raw"),
            sampledSnapshotCacheRootURL: URL(fileURLWithPath: "/tmp/sampled-snapshots"),
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 25 * 1024 * 1024,
            pressureGribRawMaximumByteCount: 150 * 1024 * 1024,
            wgrib2ExecutableURL: URL(fileURLWithPath: "/usr/local/bin/wgrib2"),
            wgrib2TimeoutSeconds: 15,
            anvilProfileAnalysisBaseURL: URL(string: "https://anvil.example.com"),
            anvilProfileAnalysisTimeoutSeconds: timeoutSeconds
        )
    }

    private func makeRequest() -> AnvilAnalyzeProfileRequest {
        AnvilAnalyzeProfileRequest(
            runTime: isoDate("2026-06-19T22:00:00Z"),
            forecastHour: 3,
            validTime: isoDate("2026-06-20T01:00:00Z"),
            location: AnvilLocationDTO(
                lat: 39.7392,
                lon: -104.9903,
                h3: "882681b59fffffff"
            ),
            profile: AnvilProfileDTO(
                pressureMb: [1000, 925, 850],
                heightMslM: [1560, 780, 1450],
                temperatureC: [28.4, 22.8, 17.5],
                dewpointC: [12.3, 10.1, 11.2],
                uWindMs: [-2.1, -5.4, -6.25],
                vWindMs: [4.6, 7.9, 8.75]
            )
        )
    }

    private func makeResponse(status: Int, body: Data? = nil) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [
                "Content-Type": "application/json"
            ],
            data: body
        )
    }

    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func loadFixture(named name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw TestFixtureError.missingFixture(name)
        }
        return try Data(contentsOf: url)
    }

    private func canonicalJSONString(from data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        guard let string = String(data: canonical, encoding: .utf8) else {
            throw TestFixtureError.unableToDecodeCanonicalJSON
        }
        return string
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }
}

private enum TestFixtureError: Error {
    case missingFixture(String)
    case unableToDecodeCanonicalJSON
}

private final class AnvilProfileStubHTTPClient: HTTPClient, @unchecked Sendable {
    struct Request: Sendable, Equatable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
        let timeoutSeconds: TimeInterval?
    }

    private let plannedResponse: HTTPResponse?
    private let plannedError: (any Error)?
    private(set) var requests: [Request] = []

    init(plannedResponse: HTTPResponse? = nil, plannedError: (any Error)? = nil) {
        self.plannedResponse = plannedResponse
        self.plannedError = plannedError
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        try await post(url, headers: headers, body: nil, timeoutSeconds: nil)
    }

    func head(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func post(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        requests.append(
            Request(
                method: "POST",
                url: url,
                headers: headers,
                body: body,
                timeoutSeconds: timeoutSeconds
            )
        )

        if let plannedError {
            throw plannedError
        }

        return plannedResponse ?? HTTPResponse(status: 200, headers: [:], data: nil)
    }

    func clearCache() {}

    var requestCount: Int { requests.count }
}
