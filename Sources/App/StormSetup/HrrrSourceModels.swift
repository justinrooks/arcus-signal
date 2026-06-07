import Foundation
import Vapor

enum HrrrModel: String, Content, Sendable, Equatable {
    case hrrr = "HRRR"
}

enum HrrrProduct: String, Content, Sendable, Equatable {
    case wrfsfc
}

enum HrrrDomain: String, Content, Sendable, Equatable {
    case conus
}

enum HrrrFieldSetVersion: String, Content, Sendable, Equatable {
    case tornadoV1 = "tornado-v1"
}

struct StormSetupHrrrBoundingBox: Content, Sendable, Equatable {
    let leftlon: Double
    let rightlon: Double
    let toplat: Double
    let bottomlat: Double

    init(
        around centroid: StormSetupCentroid,
        halfWidthDegrees: Double = 0.15,
        halfHeightDegrees: Double = 0.175
    ) {
        self.leftlon = centroid.longitude - halfWidthDegrees
        self.rightlon = centroid.longitude + halfWidthDegrees
        self.toplat = centroid.latitude + halfHeightDegrees
        self.bottomlat = centroid.latitude - halfHeightDegrees
    }
}

struct HrrrRunCandidate: Content, Sendable, Equatable {
    let model: HrrrModel
    let product: HrrrProduct
    let domain: HrrrDomain
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let fieldSetVersion: HrrrFieldSetVersion

    init(
        model: HrrrModel = .hrrr,
        product: HrrrProduct = .wrfsfc,
        domain: HrrrDomain = .conus,
        runTime: Date,
        forecastHour: Int,
        fieldSetVersion: HrrrFieldSetVersion = .tornadoV1
    ) {
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = Self.validTime(for: runTime, forecastHour: forecastHour)
        self.fieldSetVersion = fieldSetVersion
    }

    var directoryPath: String {
        "/hrrr.\(runTime.stormSetupUTCDateString)/\(domain.rawValue)"
    }

    var fileName: String {
        "hrrr.t\(runTime.stormSetupUTCHourString)z.\(product.rawValue)f\(forecastHour.stormSetupTwoDigitString).grib2"
    }

    private static func validTime(for runTime: Date, forecastHour: Int) -> Date {
        guard let validTime = StormSetupUTC.calendar.date(byAdding: .hour, value: forecastHour, to: runTime) else {
            preconditionFailure("Unable to derive HRRR valid time from run time and forecast hour.")
        }

        return validTime
    }
}

struct HrrrRunResolution: Sendable, Equatable {
    let targetValidTime: Date
    let candidates: [HrrrRunCandidate]

    var primaryCandidate: HrrrRunCandidate? {
        candidates.first
    }
}

enum StormSetupUTC {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()
}

private extension Date {
    var stormSetupUTCComponents: DateComponents {
        StormSetupUTC.calendar.dateComponents([.year, .month, .day, .hour], from: self)
    }

    var stormSetupUTCDateString: String {
        let components = stormSetupUTCComponents
        return components.year.stormSetupFourDigitString
            + components.month.stormSetupTwoDigitString
            + components.day.stormSetupTwoDigitString
    }

    var stormSetupUTCHourString: String {
        stormSetupUTCComponents.hour.stormSetupTwoDigitString
    }
}

private extension Optional where Wrapped == Int {
    var stormSetupTwoDigitString: String {
        guard let value = self else {
            preconditionFailure("Expected a UTC date component.")
        }

        return value.stormSetupTwoDigitString
    }

    var stormSetupFourDigitString: String {
        guard let value = self else {
            preconditionFailure("Expected a UTC year component.")
        }

        return value.stormSetupFourDigitString
    }
}

private extension Int {
    var stormSetupTwoDigitString: String {
        zeroPadded(width: 2)
    }

    var stormSetupFourDigitString: String {
        zeroPadded(width: 4)
    }

    func zeroPadded(width: Int) -> String {
        let string = String(self)
        guard string.count < width else {
            return string
        }

        return String(repeating: "0", count: width - string.count) + string
    }
}
