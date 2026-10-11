@testable import App
import ArcusCore
import Foundation
import Testing

@Suite("SPC meso source")
struct SPCMesoClientTests {
    @Test func fetchesCanonicalFeed() async throws {
        let url = try #require(Bundle.module.url(forResource: "meso", withExtension: "xml", subdirectory: "Fixtures/SPC"))
        let http = MesoHTTPStub(response: .init(status: 200, headers: [:], data: try Data(contentsOf: url)))
        let products = try await SPCMesoHTTPClient(http: http).fetchDiscussions()
        #expect(products.count == 1)
        #expect(products.first?.productID == "SPC-MD-2025-123")
        let urls = await http.urls
        #expect(urls == [SPCMesoHTTPClient.sourceURL])
    }

    @Test(arguments: [429, 503, 404, 304])
    func rejectsStatus(_ status: Int) async {
        let http = MesoHTTPStub(response: .init(status: status, headers: [:], data: Data("<rss><channel/></rss>".utf8)))
        await #expect(throws: SPCMesoError.upstreamStatus(status)) { try await SPCMesoHTTPClient(http: http).fetchDiscussions() }
    }

    @Test func rejectsMissingAndMalformedBody() async {
        for body in [nil, Data()] as [Data?] {
            let http = MesoHTTPStub(response: .init(status: 200, headers: [:], data: body))
            await #expect(throws: SPCMesoError.missingData) { try await SPCMesoHTTPClient(http: http).fetchDiscussions() }
        }
        let http = MesoHTTPStub(response: .init(status: 200, headers: [:], data: Data("invalid".utf8)))
        await #expect(throws: SPCMesoError.malformedFeed) { try await SPCMesoHTTPClient(http: http).fetchDiscussions() }
    }
}

private actor MesoHTTPStub: HTTPClient {
    let response: HTTPResponse
    var urls: [URL] = []
    init(response: HTTPResponse) { self.response = response }
    func get(_ url: URL, headers: [String: String], timeoutSeconds: TimeInterval?) async throws -> HTTPResponse {
        urls.append(url)
        return response
    }
    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse { response }
    func post(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { response }
    func postWithoutRetry(_ url: URL, headers: [String: String], body: Data?, timeoutSeconds: TimeInterval?) async throws -> HTTPResponse { response }
    nonisolated func clearCache() {}
}
