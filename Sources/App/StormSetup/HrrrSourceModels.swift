import Foundation
import Vapor
import ArcusCore

extension HrrrProduct {
    var defaultFieldSetVersion: HrrrFieldSetVersion {
        switch self {
        case .wrfsfc:
            .tornadoV1
        case .wrfprsf:
            .tornadoPressureV2
        }
    }

    var fileNameStem: String {
        switch self {
        case .wrfsfc:
            "wrfsfcf"
        case .wrfprsf:
            "wrfprsf"
        }
    }
}

extension HrrrFieldSetVersion {
    var nomadsVariableFlags: [String] {
        switch self {
        case .tornadoV1:
            ["var_CAPE", "var_CIN", "var_HLCY", "var_VUCSH", "var_VVCSH", "var_USTM", "var_VSTM", "var_HGT", "var_DPT", "var_TMP"]
        case .anvilSurfaceV1:
            ["var_PRES", "var_HGT", "var_TMP", "var_DPT", "var_UGRD", "var_VGRD"]
        case .tornadoPressureV1, .tornadoPressureV2:
            ["var_HGT", "var_TMP", "var_DPT", "var_UGRD", "var_VGRD"]
        }
    }

    var nomadsLevelFlags: [String] {
        switch self {
        case .tornadoV1:
            [
                "lev_surface", "lev_0-3000_m_above_ground", "lev_2_m_above_ground", "lev_90-0_mb_above_ground",
                "lev_255-0_mb_above_ground", "lev_1000-0_m_above_ground", "lev_3000-0_m_above_ground",
                "lev_0-6000_m_above_ground", "lev_level_of_adiabatic_condensation_from_sfc"
            ]
        case .anvilSurfaceV1:
            ["lev_surface", "lev_2_m_above_ground", "lev_10_m_above_ground"]
        case .tornadoPressureV1:
            ["lev_1000_mb", "lev_925_mb", "lev_850_mb", "lev_700_mb", "lev_500_mb", "lev_300_mb", "lev_250_mb"]
        case .tornadoPressureV2:
            [
                "lev_1000_mb", "lev_975_mb", "lev_950_mb", "lev_925_mb", "lev_900_mb", "lev_875_mb",
                "lev_850_mb", "lev_825_mb", "lev_800_mb", "lev_775_mb", "lev_750_mb", "lev_725_mb",
                "lev_700_mb", "lev_675_mb", "lev_650_mb", "lev_625_mb", "lev_600_mb", "lev_575_mb",
                "lev_550_mb", "lev_525_mb", "lev_500_mb", "lev_475_mb", "lev_450_mb", "lev_425_mb",
                "lev_400_mb", "lev_375_mb", "lev_350_mb", "lev_325_mb", "lev_300_mb", "lev_275_mb",
                "lev_250_mb", "lev_225_mb", "lev_200_mb", "lev_175_mb", "lev_150_mb", "lev_125_mb",
                "lev_100_mb"
            ]
        }
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
        fieldSetVersion: HrrrFieldSetVersion? = nil
    ) {
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = runTime.addingTimeInterval(TimeInterval(forecastHour) * 3600)
        self.fieldSetVersion = fieldSetVersion ?? product.defaultFieldSetVersion
    }

    var directoryPath: String {
        "/hrrr.\(runTime.stormSetupUTCDateString)/\(domain.rawValue)"
    }

    var fileName: String {
        "hrrr.t\(runTime.stormSetupUTCHourString)z.\(product.fileNameStem)\(forecastHour.stormSetupTwoDigitString).grib2"
    }
}

enum HrrrSurfaceToPressureCandidatePolicy {
    static func makePressureCandidate(from candidate: HrrrRunCandidate) -> HrrrRunCandidate {
        let runTime = StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: candidate.runTime) ?? candidate.runTime
        return HrrrRunCandidate(
            model: candidate.model,
            product: .wrfprsf,
            domain: candidate.domain,
            runTime: runTime,
            forecastHour: candidate.forecastHour + 1,
            fieldSetVersion: HrrrProduct.wrfprsf.defaultFieldSetVersion
        )
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
