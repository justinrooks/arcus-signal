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
        self.validTime = runTime.addingTimeInterval(TimeInterval(forecastHour) * 3600)
        self.fieldSetVersion = fieldSetVersion
    }

    var directoryPath: String {
        "/hrrr.\(runTime.stormSetupUTCDateString)/\(domain.rawValue)"
    }

    var fileName: String {
        "hrrr.t\(runTime.stormSetupUTCHourString)z.\(product.rawValue)f\(forecastHour.stormSetupTwoDigitString).grib2"
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
    var stormSetupUTCDateString: String {
        let year = StormSetupUTC.calendar.component(.year, from: self)
        let month = StormSetupUTC.calendar.component(.month, from: self)
        let day = StormSetupUTC.calendar.component(.day, from: self)
        return year.stormSetupFourDigitString
            + month.stormSetupTwoDigitString
            + day.stormSetupTwoDigitString
    }

    var stormSetupUTCHourString: String {
        StormSetupUTC.calendar.component(.hour, from: self).stormSetupTwoDigitString
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
