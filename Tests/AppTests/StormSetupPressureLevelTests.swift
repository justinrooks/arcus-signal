@testable import App
import Testing

@Suite("Storm setup pressure levels", .serialized)
struct StormSetupPressureLevelTests {
    @Test("preferred descending pressure levels match the expanded contract")
    func preferredDescendingPressureLevelsMatchExpandedContract() {
        #expect(StormSetupPressureLevel.preferredDescending.map(\.pressureMb) == expandedPressureLevels)
    }

    @Test("required pressure levels parse from mb strings")
    func requiredPressureLevelsParseFromMbStrings() {
        for pressureMb in expandedPressureLevels {
            #expect(StormSetupPressureLevel.parse(from: "\(pressureMb) mb")?.pressureMb == pressureMb)
        }
    }

    @Test("excluded lower pressure levels do not parse")
    func excludedLowerPressureLevelsDoNotParse() {
        for pressureMb in [90, 80, 70, 60, 50] {
            #expect(StormSetupPressureLevel.parse(from: "\(pressureMb) mb") == nil)
        }
    }
}

private let expandedPressureLevels = [
    1000, 975, 950, 925, 900, 875, 850, 825, 800, 775, 750, 725,
    700, 675, 650, 625, 600, 575, 550, 525, 500, 475, 450, 425,
    400, 375, 350, 325, 300, 275, 250, 225, 200, 175, 150, 125, 100
]
