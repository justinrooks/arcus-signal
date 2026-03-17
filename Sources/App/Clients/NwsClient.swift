//
//  NwsClient.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//

import Foundation
import Logging

enum NwsError: Error, Equatable {
    case invalidUrl
    case parsingError
    case missingData
    case networkError(status: Int)
    case rateLimited(retryAfterSeconds: Int?)
    case serviceUnavailable(retryAfterSeconds: Int?)
}

protocol NwsClient: Sendable {
    func fetchActiveAlertsJsonData() async throws -> Data
}

// https://api.weather.gov/alerts/active?status=actual&region_type=land&severity=Extreme,Severe,Moderate
// https://api.weather.gov/alerts?event=Nuclear%20Power%20Plant%20Warning,Lakeshore%20Flood%20Watch&limit=500
// https://api.weather.gov/alerts/active?point=39%2C-104
// https://api.weather.gov/alerts/active?status=actual&message_type=alert,update&point=39%2C-104
//https://api.weather.gov/alerts/active?status=actual&event=tornado%20warning,severe%20thunderstorm%20warning,flash%20flood%20warning,tornado%20watch,severe%20thunderstorm%20watch,winter%20storm%20warning,extreme%20fire%20danger,fire%20warning,fire%20weather%20watch,red%20flag%20warning&region_type=land

struct NwsHttpClient: NwsClient {
    private let http: any HTTPClient
    private let logger = Logger.providersNwsClient
    private static let baseURL = URL(string: "https://api.weather.gov")!
    
    init(http: any HTTPClient) {
        self.http = http
    }
    
    func fetchActiveAlertsJsonData() async throws -> Data {
        logger.info("NWS request started")
        let supportedEvents: URLQueryItem = getSupportedEventsQueryParameter()
        let url = try makeNwsUrl(
            path: "/alerts/active",
            queryItems: [supportedEvents, URLQueryItem(name: "status", value: "actual"), URLQueryItem(name: "region_type", value: "land")]
        )

        return try await fetch(from: url)
    }

    private var requestHeaders: [String: String] {
        HTTPRequestHeaders.nws()
    }
    
    private func fetch(from url: URL) async throws -> Data {
        try Task.checkCancellation()

        let resp = try await http.get(url, headers: requestHeaders)
        try Task.checkCancellation()
        
        switch resp.classifyStatus() {
        case .success:
            break
        case .rateLimited(let retryAfter):
            let error = NwsError.rateLimited(retryAfterSeconds: retryAfter)
            logFailure(error: error, endpoint: url.path, status: resp.status)
            throw error
        case .serviceUnavailable(let retryAfter):
            let error = NwsError.serviceUnavailable(retryAfterSeconds: retryAfter)
            logFailure(error: error, endpoint: url.path, status: resp.status)
            throw error
        case .failure(let status):
            let error = NwsError.networkError(status: status)
            logFailure(error: error, endpoint: url.path, status: status)
            throw error
        }
        
        guard let data = resp.data else {
            logger.error(
                "NWS response missing body.",
                metadata: [
                    "endpoint": .string(url.path),
                    "status": .string("\(resp.status)")
                ]
            )
            throw NwsError.missingData
        }
        
        return data
    }

    private func logFailure(error: NwsError, endpoint: String, status: Int) {
        switch error {
        case .rateLimited(let retryAfter):
            logger.warning(
                "NWS rate limited.",
                metadata: [
                    "endpoint": .string(endpoint),
                    "status": .string("\(status)"),
                    "retryAfterSeconds": .string("\(retryAfter ?? -1)")
                ]
            )
        case .serviceUnavailable(let retryAfter):
            logger.warning(
                "NWS service unavailable.",
                metadata: [
                    "endpoint": .string(endpoint),
                    "status": .string("\(status)"),
                    "retryAfterSeconds": .string("\(retryAfter ?? -1)")
                ]
            )
        default:
            logger.error(
                "NWS request failed.",
                metadata: [
                    "endpoint": .string(endpoint),
                    "status": .string("\(status)")
                ]
            )
        }
    }
    
    /// Build an absolute NWS URL from a relative path, or throw on failure.
    private func makeNwsUrl(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false) else {
            throw NwsError.invalidUrl
        }
        
        components.path = path
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        
        guard let url = components.url else { throw NwsError.invalidUrl }
        return url
    }
    
    private func getSupportedEventsQueryParameter() -> URLQueryItem {
        let supportedEvents: [String] = [
            //"911 Telephone Outage",
            //"Administrative Message",
            "Air Quality Alert",
            //"Air Stagnation Advisory",
            //"Ashfall Advisory",
            //"Ashfall Warning",
            //"Avalanche Advisory",
            //"Avalanche Warning",
            //"Avalanche Watch",
            //"Beach Hazards Statement",
            "Blizzard Warning",
            //"Blowing Dust Advisory",
            //"Blowing Dust Warning",
            //"Blue Alert",
            //"Brisk Wind Advisory",
            //"Child Abduction Emergency",
            //"Civil Danger Warning",
            //"Civil Emergency Message",
            //"Coastal Flood Advisory",
            //"Coastal Flood Statement",
            //"Coastal Flood Warning",
            //"Coastal Flood Watch",
            //"Cold Weather Advisory",
            //"Dense Fog Advisory",
            //"Dense Smoke Advisory",
            //"Dust Advisory",
            //"Dust Storm Warning",
            "Earthquake Warning",
            "Evacuation Immediate",
            //"Extreme Heat Warning",
            //"Extreme Heat Watch",
            //"Extreme Cold Warning",
            //"Extreme Cold Watch",
            "Extreme Fire Danger",
            "Extreme Wind Warning",
            "Fire Warning",
            "Fire Weather Watch",
            "Flash Flood Statement",
            "Flash Flood Warning",
            "Flash Flood Watch",
            //"Flood Advisory",
            //"Flood Statement",
            "Flood Warning",
            "Flood Watch",
            //"Freeze Warning",
            //"Freeze Watch",
            //"Freezing Fog Advisory",
            //"Freezing Spray Advisory",
            //"Frost Advisory",
            //"Gale Warning",
            //"Gale Watch",
            //"Hazardous Materials Warning",
            //"Hazardous Seas Warning",
            //"Hazardous Seas Watch",
            //"Hazardous Weather Outlook",
            //"Heat Advisory",
            //"Heavy Freezing Spray Warning",
            //"Heavy Freezing Spray Watch",
            //"High Surf Advisory",
            //"High Surf Warning",
            "High Wind Warning",
            "High Wind Watch",
            //"Hurricane Force Wind Warning",
            //"Hurricane Force Wind Watch",
            //"Hurricane Warning",
            //"Hurricane Watch",
            //"Hydrologic Outlook",
            //"Ice Storm Warning",
            //"Lake Effect Snow Warning",
            //"Lake Wind Advisory",
            //"Lakeshore Flood Advisory",
            //"Lakeshore Flood Statement",
            //"Lakeshore Flood Warning",
            //"Lakeshore Flood Watch",
            //"Law Enforcement Warning",
            //"Local Area Emergency",
            //"Low Water Advisory",
            //"Marine Weather Statement",
            "Nuclear Power Plant Warning",
            //"Radiological Hazard Warning",
            "Red Flag Warning",
            //"Rip Current Statement",
            "Severe Thunderstorm Warning",
            "Severe Thunderstorm Watch",
            "Severe Weather Statement",
            //"Shelter In Place Warning",
            //"Short Term Forecast",
            //"Small Craft Advisory",
            "Snow Squall Warning",
            //"Special Marine Warning",
            //"Special Weather Statement",
            //"Storm Surge Warning",
            //"Storm Surge Watch",
            //"Storm Warning",
            //"Storm Watch",
            //"Test",
            "Tornado Warning",
            "Tornado Watch",
            //"Tropical Cyclone Local Statement",
            //"Tropical Storm Warning",
            //"Tropical Storm Watch",
            //"Tsunami Advisory",
            //"Tsunami Warning",
            //"Tsunami Watch",
            //"Typhoon Warning",
            //"Typhoon Watch",
            "Volcano Warning",
//            "Wind Advisory",
            "Winter Storm Warning",
            "Winter Storm Watch",
            "Winter Weather Advisory"
        ]
        
        return .init(name: "event", value: supportedEvents.joined(separator: ","))
    }
}
