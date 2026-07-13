import Foundation
import Logging

enum AirNowClientError: Error, Sendable {
    case invalidURL
    case missingData
    case upstreamFailure(status: Int)
}

protocol AirNowClient: Sendable {
    func fetchCurrentObservations(latitude: Double, longitude: Double) async throws -> [AirNowObservation]
}

struct DefaultAirNowClient: AirNowClient {
    private let http: any HTTPClient
    private let apiKey: String
    private let baseURL: URL
    private let logger: Logger

    init(
        apiKey: String,
        http: any HTTPClient,
        baseURL: URL = URL(string: "https://www.airnowapi.org")!,
        logger: Logger = .networkDownloader
    ) {
        self.apiKey = apiKey
        self.http = http
        self.baseURL = baseURL
        self.logger = logger
    }

    func fetchCurrentObservations(latitude: Double, longitude: Double) async throws -> [AirNowObservation] {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AirNowClientError.invalidURL
        }
//        https://www.airnowapi.org/aq/observation/current/ziplatlong/?format=application/json&latitude=39.753&longitude=-104.44991&API_KEY=70D98E07-5A66-4B59-8A83-529D198B4E72
        components.path = "/aq/observation/current/ziplatlong/"
        components.queryItems = [
            .init(name: "format", value: "application/json"),
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "distance", value: "25"),
            .init(name: "API_KEY", value: apiKey)
        ]
        guard let url = components.url else { throw AirNowClientError.invalidURL }

        let response = try await http.get(url, headers: ["Accept": "application/json"])
        guard (200...299).contains(response.status) else {
            logger.warning("AirNow request failed status=\(response.status)")
            throw AirNowClientError.upstreamFailure(status: response.status)
        }
        guard let data = response.data else { throw AirNowClientError.missingData }
        return try JSONDecoder().decode([AirNowObservation].self, from: data)
    }
}
