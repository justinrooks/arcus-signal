import ArcusCore
import Foundation

protocol SPCMesoClient: Sendable {
    func fetchDiscussions() async throws -> [MesoscaleDiscussionPayload]
}

enum SPCMesoError: Error, Equatable {
    case upstreamStatus(Int)
    case missingData
    case malformedFeed
    case malformedDiscussion(String)
}

struct SPCMesoHTTPClient: SPCMesoClient {
    private let http: any HTTPClient
    static let sourceURL = URL(string: "https://www.spc.noaa.gov/products/spcmdrss.xml")!

    init(http: any HTTPClient) { self.http = http }

    func fetchDiscussions() async throws -> [MesoscaleDiscussionPayload] {
        try Task.checkCancellation()
        let response = try await http.get(Self.sourceURL, headers: ["Accept": "application/rss+xml, application/xml"])
        try Task.checkCancellation()
        guard (200...299).contains(response.status) else {
            throw SPCMesoError.upstreamStatus(response.status)
        }
        guard let data = response.data, !data.isEmpty else { throw SPCMesoError.missingData }
        return try SPCMesoParser.parse(data)
    }
}
