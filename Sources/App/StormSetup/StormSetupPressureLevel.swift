import Foundation

enum StormSetupPressureLevel: Int, Sendable, Codable, CaseIterable, Comparable {
    case mb1000 = 1000
    case mb975 = 975
    case mb950 = 950
    case mb925 = 925
    case mb900 = 900
    case mb875 = 875
    case mb850 = 850
    case mb825 = 825
    case mb800 = 800
    case mb775 = 775
    case mb750 = 750
    case mb725 = 725
    case mb700 = 700
    case mb675 = 675
    case mb650 = 650
    case mb625 = 625
    case mb600 = 600
    case mb575 = 575
    case mb550 = 550
    case mb525 = 525
    case mb500 = 500
    case mb475 = 475
    case mb450 = 450
    case mb425 = 425
    case mb400 = 400
    case mb375 = 375
    case mb350 = 350
    case mb325 = 325
    case mb300 = 300
    case mb275 = 275
    case mb250 = 250
    case mb225 = 225
    case mb200 = 200
    case mb175 = 175
    case mb150 = 150
    case mb125 = 125
    case mb100 = 100

    static let preferredDescending: [StormSetupPressureLevel] = Self.allCases

    var pressureMb: Int {
        rawValue
    }

    static func < (lhs: StormSetupPressureLevel, rhs: StormSetupPressureLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    static func parse(from levelText: String) -> StormSetupPressureLevel? {
        let normalized = normalize(levelText)
        guard normalized.hasSuffix(" mb") else {
            return nil
        }

        let pressureText = normalized.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let pressureText, let pressureMb = Int(pressureText) else {
            return nil
        }

        return StormSetupPressureLevel(rawValue: pressureMb)
    }

    private static func normalize(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}

enum StormSetupPressureProfileVariable: String, Sendable, Codable, CaseIterable {
    case hgt = "HGT"
    case tmp = "TMP"
    case dpt = "DPT"
    case ugrd = "UGRD"
    case vgrd = "VGRD"
}
