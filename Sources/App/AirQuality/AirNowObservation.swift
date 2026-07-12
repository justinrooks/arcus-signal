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
    let category: Category?

    enum CodingKeys: String, CodingKey {
        case dateObserved = "DateObserved"
        case hourObserved = "HourObserved"
        case localTimeZone = "LocalTimeZone"
        case parameterName = "ParameterName"
        case aqi = "AQI"
        case category = "Category"
    }
}
