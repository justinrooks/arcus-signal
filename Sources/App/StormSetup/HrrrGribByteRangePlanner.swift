import Foundation

struct HrrrGribByteRangePlanner: Sendable {
    func plan(
        inventory: HrrrPressureIdxInventory,
        selectedMessages: [HrrrPressureProfileSelectedMessage]
    ) -> HrrrGribByteRangePlan {
        let ranges = selectedMessages.map { selectedMessage in
            let nextOffset = inventory.records.indices.contains(selectedMessage.inventoryIndex + 1)
                ? inventory.records[selectedMessage.inventoryIndex + 1].byteOffset
                : nil

            return HrrrGribByteRange(
                startOffset: selectedMessage.record.byteOffset,
                endOffset: nextOffset.map { $0 - 1 },
                inventoryIndex: selectedMessage.inventoryIndex,
                selectedMessage: selectedMessage
            )
        }

        return HrrrGribByteRangePlan(ranges: ranges)
    }
}

struct HrrrGribByteRangePlan: Sendable, Equatable {
    let ranges: [HrrrGribByteRange]
}

struct HrrrGribByteRange: Sendable, Equatable {
    let startOffset: Int64
    let endOffset: Int64?
    let inventoryIndex: Int
    let selectedMessage: HrrrPressureProfileSelectedMessage

    var closedRange: ClosedRange<Int64>? {
        guard let endOffset else {
            return nil
        }

        return startOffset...endOffset
    }

    var isTerminal: Bool {
        endOffset == nil
    }

    var httpRangeHeaderValue: String {
        if let endOffset {
            return "bytes=\(startOffset)-\(endOffset)"
        }

        return "bytes=\(startOffset)-"
    }
}
