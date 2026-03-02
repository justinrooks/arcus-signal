//
//  NwsEventJson.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//
// This is the shape of the incomming JSON from the NWS for alerts
// We are really only concerned with the array of NwsEventFeatureDTOs
// and children. The NwsEventDTO is just a parent container for
// serialization.
// api.weather.gov/alerts

import Foundation

// MARK: - Root
public struct NwsEventDTO: Codable, Sendable {
    public let type: String
    public let features: [NwsEventFeatureDTO]?
    public let title: String?
    public let updated: Date?
    public let pagination: NWSPaginationDTO?

    enum CodingKeys: String, CodingKey {
        case type
        case features
        case title
        case updated
        case pagination
    }
}

// MARK: - Feature
public struct NwsEventFeatureDTO: Codable, Sendable {
    public let context: [String]?
    public let id: String
    public let type: String
    public let geometry: NWSGeometryDTO?
    public let properties: NwsEventPropertiesDTO

    enum CodingKeys: String, CodingKey {
        case context = "@context"
        case id
        case type
        case geometry
        case properties
    }
}

// MARK: - Geometry

public struct NWSGeometryDTO: Codable, Sendable {
    public let type: String
    public let coordinates: NWSCoordinatesDTO
    public let bbox: [Double]?
}

public indirect enum NWSCoordinatesDTO: Codable, Sendable, Equatable {
    case number(Double)
    case array([NWSCoordinatesDTO])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }

        if let values = try? container.decode([NWSCoordinatesDTO].self) {
            self = .array(values)
            return
        }

        throw DecodingError.typeMismatch(
            NWSCoordinatesDTO.self,
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Expected a number or nested number array for GeoJSON coordinates."
            )
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .number(let value):
            try container.encode(value)
        case .array(let values):
            try container.encode(values)
        }
    }
}

// MARK: - Properties

public struct NwsEventPropertiesDTO: Codable, Sendable {
    public let id: String
    public let areaDesc: String
    public let geocode: NWSGeocodeDTO?
    public let affectedZones: [String]?
    public let references: [NWSReferenceDTO]?

    public let sent: Date?
    public let effective: Date?
    public let onset: Date?
    public let expires: Date?
    public let ends: Date?

    public let status: String?        // e.g. "Actual"
    public let messageType: String?   // e.g. "Alert"
    public let category: String?      // e.g. "Met"
    public let severity: String?      // e.g. "Extreme"
    public let certainty: String?     // e.g. "Observed"
    public let urgency: String?       // e.g. "Immediate"

    public let event: String?
    public let sender: String?
    public let senderName: String?

    public let headline: String?
    public let description: String?
    public let instruction: String?
    public let response: String?      // e.g. "Shelter"

    public let parameters: [String: [String]]?
    public let scope: String?
    public let code: String?
    public let language: String?
    public let web: String?
    public let eventCode: [String: [String]]?

    enum CodingKeys: String, CodingKey {
        case id
        case areaDesc
        case geocode
        case affectedZones
        case references

        case sent
        case effective
        case onset
        case expires
        case ends

        case status
        case messageType
        case category
        case severity
        case certainty
        case urgency

        case event
        case sender
        case senderName

        case headline
        case description
        case instruction
        case response

        case parameters
        case scope
        case code
        case language
        case web
        case eventCode
    }
}

// MARK: - Nested types

public struct NWSGeocodeDTO: Codable, Sendable {
    public let ugc: [String]?
    public let same: [String]?

    enum CodingKeys: String, CodingKey {
        case ugc = "UGC"
        case same = "SAME"
    }
}

public struct NWSReferenceDTO: Codable, Sendable {
    public let id: String
    public let identifier: String
    public let sender: String
    public let sent: Date

    enum CodingKeys: String, CodingKey {
        case id = "@id"
        case identifier
        case sender
        case sent
    }
}

public struct NWSPaginationDTO: Codable, Sendable {
    public let next: String?
}
