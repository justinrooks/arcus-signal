@testable import App
import Foundation
import Testing

@Suite("HRRR pressure profile message selector", .serialized)
struct HrrrPressureProfileMessageSelectorTests {
    @Test("fixture selects the exact required records for a complete level")
    func fixtureSelectsExactRequiredRecordsForCompleteLevel() throws {
        let inventory = try loadFixtureInventory()
        let result = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)

        #expect(result.requestedLevels == [.mb1000])
        #expect(result.missingLevels.isEmpty)
        #expect(result.ignoredRecords.isEmpty)
        #expect(result.selectedMessages.count == 5)
        #expect(result.selectedMessages.map(\.pressureLevel) == Array(repeating: .mb1000, count: 5))
        #expect(result.selectedMessages.map(\.variable) == [.hgt, .tmp, .dpt, .ugrd, .vgrd])
        #expect(result.selectedMessages.map(\.record.rawLine) == [
            "1:0:d=2026060313:HGT:1000 mb:9 hour fcst:",
            "2:1487:d=2026060313:TMP:1000 mb:9 hour fcst:",
            "3:2975:d=2026060313:DPT:1000 mb:9 hour fcst:",
            "4:4461:d=2026060313:UGRD:1000 mb:9 hour fcst:",
            "5:5947:d=2026060313:VGRD:1000 mb:9 hour fcst:"
        ])
    }

    @Test("missing variables are reported per pressure level")
    func missingVariablesAreReportedPerPressureLevel() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:1487:d=2026060313:TMP:1000 mb:9 hour fcst:
            3:2975:d=2026060313:DPT:1000 mb:9 hour fcst:
            4:4461:d=2026060313:UGRD:1000 mb:9 hour fcst:
            5:5947:d=2026060313:VGRD:1000 mb:9 hour fcst:
            6:7434:d=2026060313:HGT:925 mb:9 hour fcst:
            7:8900:d=2026060313:TMP:925 mb:9 hour fcst:
            8:10387:d=2026060313:UGRD:925 mb:9 hour fcst:
            9:11874:d=2026060313:VGRD:925 mb:9 hour fcst:
            10:13361:d=2026060313:HGT:850 mb:9 hour fcst:
            11:14847:d=2026060313:TMP:850 mb:9 hour fcst:
            12:16334:d=2026060313:DPT:850 mb:9 hour fcst:
            13:17821:d=2026060313:UGRD:850 mb:9 hour fcst:
            """
        )

        let result = HrrrPressureProfileMessageSelector().select(inventory: inventory)

        #expect(result.selectedMessages.map(\.pressureLevel) == Array(repeating: .mb1000, count: 5))

        let missing925 = result.missingLevels.first(where: { $0.pressureMb == 925 })
        let missing850 = result.missingLevels.first(where: { $0.pressureMb == 850 })

        #expect(missing925?.missingVariables == [.dpt])
        #expect(missing850?.missingVariables == [.vgrd])
    }

    @Test("unknown variables and unrequested levels are ignored")
    func unknownVariablesAndUnrequestedLevelsAreIgnored() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:WIND:1000 mb:9 hour fcst:
            2:1487:d=2026060313:HGT:1000 mb:9 hour fcst:
            3:2975:d=2026060313:TMP:1000 mb:9 hour fcst:
            4:4461:d=2026060313:DPT:1000 mb:9 hour fcst:
            5:5947:d=2026060313:UGRD:1000 mb:9 hour fcst:
            6:7434:d=2026060313:VGRD:1000 mb:9 hour fcst:
            7:8900:d=2026060313:HGT:200 mb:9 hour fcst:
            8:10387:d=2026060313:TMP:200 mb:9 hour fcst:
            9:11874:d=2026060313:DPT:200 mb:9 hour fcst:
            10:13361:d=2026060313:UGRD:200 mb:9 hour fcst:
            11:14847:d=2026060313:VGRD:200 mb:9 hour fcst:
            """
        )

        let result = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)

        #expect(result.selectedMessages.map(\.pressureLevel) == Array(repeating: .mb1000, count: 5))
        #expect(result.ignoredRecords.contains(where: { matches($0.reason, .unsupportedVariable("WIND")) }))
        #expect(result.ignoredRecords.contains(where: { matches($0.reason, .unsupportedPressureLevel("200 mb")) }))
    }

    @Test("selected messages preserve inventory order for deterministic concatenation")
    func selectedMessagesPreserveInventoryOrder() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:UGRD:1000 mb:9 hour fcst:
            2:1487:d=2026060313:HGT:1000 mb:9 hour fcst:
            3:2975:d=2026060313:VGRD:1000 mb:9 hour fcst:
            4:4461:d=2026060313:TMP:1000 mb:9 hour fcst:
            5:5947:d=2026060313:DPT:1000 mb:9 hour fcst:
            """
        )

        let result = HrrrPressureProfileMessageSelector().select(inventory: inventory)

        #expect(result.selectedMessages.map(\.variable) == [.ugrd, .hgt, .vgrd, .tmp, .dpt])
        #expect(result.selectedMessages.map(\.record.byteOffset) == [0, 1487, 2975, 4461, 5947])
    }

    private func loadFixtureInventory() throws -> HrrrPressureIdxInventory {
        guard let url = Bundle.module.url(forResource: "HrrrPressureSample", withExtension: "idx", subdirectory: "Fixtures") else {
            Issue.record("Missing HrrrPressureSample.idx fixture.")
            throw FixtureError.missingFixture
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return HrrrPressureIdxInventory.parse(text)
    }

    private func matches(_ actual: HrrrPressureProfileIgnoredRecordReason, _ expected: HrrrPressureProfileIgnoredRecordReason) -> Bool {
        switch (actual, expected) {
        case (.unsupportedVariable(let lhs), .unsupportedVariable(let rhs)):
            return lhs == rhs
        case (.unsupportedPressureLevel(let lhs), .unsupportedPressureLevel(let rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

private enum FixtureError: Error {
    case missingFixture
}
