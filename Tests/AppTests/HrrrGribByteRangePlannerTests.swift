@testable import App
import Foundation
import Testing

@Suite("HRRR GRIB byte-range planner", .serialized)
struct HrrrGribByteRangePlannerTests {
    @Test("byte ranges are closed using the next inventory record offset")
    func byteRangesAreClosedUsingNextInventoryRecordOffset() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:1487:d=2026060313:TMP:1000 mb:9 hour fcst:
            3:2975:d=2026060313:DPT:1000 mb:9 hour fcst:
            4:4461:d=2026060313:UGRD:1000 mb:9 hour fcst:
            5:5947:d=2026060313:VGRD:1000 mb:9 hour fcst:
            6:7434:d=2026060313:HGT:925 mb:9 hour fcst:
            """
        )
        let selection = HrrrPressureProfileMessageSelector().select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)

        #expect(plan.ranges.count == 5)
        #expect(plan.ranges.map(\.closedRange) == [
            0...1486,
            1487...2974,
            2975...4460,
            4461...5946,
            5947...7433
        ])
        #expect(plan.ranges.allSatisfy { $0.isTerminal == false })
        #expect(plan.ranges.map(\.httpRangeHeaderValue) == [
            "bytes=0-1486",
            "bytes=1487-2974",
            "bytes=2975-4460",
            "bytes=4461-5946",
            "bytes=5947-7433"
        ])
    }

    @Test("final selected-message ranges are explicitly left open-ended")
    func finalSelectedMessageRangesAreExplicitlyLeftOpenEnded() {
        let inventory = HrrrPressureIdxInventory.parse(
            """
            1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
            2:1487:d=2026060313:TMP:1000 mb:9 hour fcst:
            3:2975:d=2026060313:DPT:1000 mb:9 hour fcst:
            4:4461:d=2026060313:UGRD:1000 mb:9 hour fcst:
            5:5947:d=2026060313:VGRD:1000 mb:9 hour fcst:
            """
        )
        let selection = HrrrPressureProfileMessageSelector().select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)

        #expect(plan.ranges.count == 5)
        #expect(plan.ranges.last?.closedRange == nil)
        #expect(plan.ranges.last?.isTerminal == true)
        #expect(plan.ranges.last?.httpRangeHeaderValue == "bytes=5947-")
    }
}
