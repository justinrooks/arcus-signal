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
    func fetchActiveAlertsJsonData(for location: Coordinate2D) async throws -> Data
    func fetchPointMetadata(for location: Coordinate2D) async throws -> Data
}

//https://api.weather.gov/alerts/active?point=39%2C-104
//https://api.weather.gov/alerts/active?status=actual&message_type=alert,update&point=39%2C-104
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
        let url = try makeNwsUrl(
            path: "/alerts/active",
            queryItems: [URLQueryItem(name: "status", value: "actual"), URLQueryItem(name: "region_type", value: "land")]
        )
//        https://api.weather.gov/alerts/active?status=actual&region_type=land&severity=Extreme,Severe,Moderate
        
        return try await fetch(from: url)
    }
    
    func fetchActiveAlertsJsonData(for location: Coordinate2D) async throws -> Data {
        let (lat, lon) = truncatedCoordinates(for: location)
        logger.info(
            "NWS request started endpoint=/alerts/active(point)",
            metadata: [
                "lat": .string("\(lat)"),
                "lon": .string("\(lon)")
            ]
        )
        let point = "\(lat),\(lon)"
        let url = try makeNwsUrl(
            path: "/alerts/active",
            queryItems: [URLQueryItem(name: "point", value: point)]
        )
        
        return try await fetch(from: url)
    }
    
    func fetchPointMetadata(for location: Coordinate2D) async throws -> Data {
        let (lat, lon) = truncatedCoordinates(for: location)
        logger.info(
            "NWS request started endpoint=/points",
            metadata: [
                "lat": .string("\(lat)"),
                "lon": .string("\(lon)")
            ]
        )
        let url = try makeNwsUrl(path: "/points/\(lat),\(lon)")
        
        return try await fetch(from: url)
    }
    
    private func truncatedCoordinates(for location: Coordinate2D) -> (Double, Double) {
        (
            location.latitude.truncated(to: 4), // NWS api only accepts 4 points of precision
            location.longitude.truncated(to: 4)
        )
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
}
