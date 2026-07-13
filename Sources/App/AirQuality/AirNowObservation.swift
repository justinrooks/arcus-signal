import Foundation

struct AirNowObservation: Decodable, Sendable, Equatable {
    struct Category: Decodable, Sendable, Equatable {
        let number: Int?
        let name: String?

        enum CodingKeys: String, CodingKey {
            case number = "Number"
            case name = "Name"
        }
    }

    let dateObserved: String
    let hourObserved: Int
    let localTimeZone: String?
    let parameterName: String?
    let aqi: Int?
    let aqiCategoryName: String?
    let category: Category?

    enum CodingKeys: String, CodingKey {
        case dateObserved
        case dateObservedLegacy = "DateObserved"
        case hourObserved
        case hourObservedLegacy = "HourObserved"
        case localTimeZone
        case localTimeZoneLegacy = "LocalTimeZone"
        case parameterName
        case parameterNameLegacy = "ParameterName"
        case aqi = "nowcastAQI"
        case aqiLegacy = "AQI"
        case aqiCategoryName
        case category = "Category"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        dateObserved = try Self.decodeString(for: [.dateObserved, .dateObservedLegacy], in: container)
        hourObserved = try Self.decodeHourObserved(for: [.hourObserved, .hourObservedLegacy], in: container)
        localTimeZone = Self.decodeStringIfPresent(for: [.localTimeZone, .localTimeZoneLegacy], in: container)
        parameterName = Self.decodeStringIfPresent(for: [.parameterName, .parameterNameLegacy], in: container)
        aqi = Self.decodeIntIfPresent(for: [.aqi, .aqiLegacy], in: container)
        aqiCategoryName = Self.decodeStringIfPresent(for: [.aqiCategoryName], in: container)
        category = try container.decodeIfPresent(Category.self, forKey: .category)
    }

    private static func decodeString(
        for keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing string value")
        )
    }

    private static func decodeStringIfPresent(
        for keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeIntIfPresent(
        for keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) -> Int? {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func decodeHourObserved(
        for keys: [CodingKeys],
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int {
        for key in keys {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }

            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                if let hour = Int(value.split(separator: ":").first ?? "") {
                    return hour
                }
            }
        }

        throw DecodingError.keyNotFound(
            keys[0],
            DecodingError.Context(codingPath: container.codingPath, debugDescription: "Missing hourObserved value")
        )
    }
}
