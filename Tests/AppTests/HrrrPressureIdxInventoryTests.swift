@testable import App
import Foundation
import Testing

@Suite("HRRR pressure IDX inventory", .serialized)
struct HrrrPressureIdxInventoryTests {
    @Test("fixture parses representative pressure inventory lines")
    func fixtureParsesRepresentativeLines() throws {
        let inventory = try loadFixtureInventory()

        #expect(inventory.records.count == 5)

        let first = try #require(inventory.records.first)
        #expect(first.messageNumber == 1)
        #expect(first.byteOffset == 0)
        #expect(first.dateRunToken == "d=2026060313")
        #expect(first.variableToken == "HGT")
        #expect(first.levelText == "1000 mb")
        #expect(first.forecastLabel == "9 hour fcst")
        #expect(first.rawLine == "1:0:d=2026060313:HGT:1000 mb:9 hour fcst:")
    }

    @Test("malformed lines are skipped without crashing")
    func malformedLinesAreSkipped() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            not even an idx line
            1:not-a-number:d=2026060313:HGT:1000 mb:9 hour fcst:
            1:0:d=2026060313:HGT
            2:128:d=2026060313:TMP:1000 mb:9 hour fcst:
            """
        )

        #expect(inventory.records.count == 1)
        #expect(inventory.records.first?.variableToken == "TMP")
        #expect(inventory.records.first?.byteOffset == 128)
    }

    @Test("extra unsupported fields stay attached to the forecast label")
    func extraFieldsRemainAttachedToForecastLabel() {
        let inventory = HrrrPressureIdxInventory.parse(
            "1:0:d=2026060313:HGT:1000 mb:9 hour fcst:extra:unsupported:field"
        )

        #expect(inventory.records.count == 1)
        #expect(inventory.records.first?.forecastLabel == "9 hour fcst:extra:unsupported:field")
        #expect(inventory.records.first?.rawLine == "1:0:d=2026060313:HGT:1000 mb:9 hour fcst:extra:unsupported:field")
    }

    @Test("parser preserves input byte offset ordering without sorting")
    func parserPreservesInputOffsetOrdering() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:1024:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:0:d=2026060313:TMP:1000 mb:9 hour fcst:
            3:512:d=2026060313:DPT:1000 mb:9 hour fcst:
            """
        )

        #expect(inventory.records.map(\.byteOffset) == [1024, 0, 512])
        #expect(inventory.records.map(\.messageNumber) == [1, 2, 3])
    }

    @Test("duplicate variable and level records remain separate")
    func duplicateVariableLevelRecordsRemainSeparate() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:1487:d=2026060313:HGT:1000 mb:9 hour fcst:
            """
        )

        #expect(inventory.records.count == 2)
        #expect(inventory.records.map(\.messageNumber) == [1, 2])
        #expect(inventory.records.map(\.byteOffset) == [0, 1487])
        #expect(inventory.records.allSatisfy { $0.variableToken == "HGT" && $0.levelText == "1000 mb" })
    }

    private func loadFixtureInventory() throws -> HrrrPressureIdxInventory {
        guard let url = Bundle.module.url(forResource: "HrrrPressureSample", withExtension: "idx", subdirectory: "Fixtures") else {
            Issue.record("Missing HrrrPressureSample.idx fixture.")
            throw FixtureError.missingFixture
        }

        let text = try String(contentsOf: url, encoding: .utf8)
        return HrrrPressureIdxInventory.parse(text)
    }
}

private enum FixtureError: Error {
    case missingFixture
}
