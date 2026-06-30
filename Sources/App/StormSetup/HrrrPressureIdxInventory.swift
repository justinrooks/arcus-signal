import Foundation

struct HrrrPressureIdxInventory: Sendable, Equatable {
    let records: [HrrrPressureIdxInventoryRecord]

    static func parse(_ text: String) -> HrrrPressureIdxInventory {
        HrrrPressureIdxInventory(
            records: text.split(whereSeparator: \.isNewline).compactMap { line in
                parseLine(String(line))
            }
        )
    }

    private static func parseLine(_ rawLine: String) -> HrrrPressureIdxInventoryRecord? {
        let fields = rawLine.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4 else {
            return nil
        }

        guard let messageNumber = Int(fields[0].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        guard let byteOffset = Int64(fields[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        var index = 2
        var dateRunToken: String?

        if fields.indices.contains(index) {
            let token = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if token.hasPrefix("d=") {
                guard !token.isEmpty else {
                    return nil
                }

                dateRunToken = token
                index += 1
            }
        }

        guard fields.count > index + 1 else {
            return nil
        }

        let variableToken = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
        let levelText = fields[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !variableToken.isEmpty, !levelText.isEmpty else {
            return nil
        }

        index += 2
        let forecastLabel = makeForecastLabel(from: fields[index...])

        return HrrrPressureIdxInventoryRecord(
            messageNumber: messageNumber,
            byteOffset: byteOffset,
            dateRunToken: dateRunToken,
            variableToken: variableToken,
            levelText: levelText,
            forecastLabel: forecastLabel,
            rawLine: rawLine
        )
    }

    private static func makeForecastLabel(from fields: ArraySlice<String>) -> String? {
        var trimmedFields = Array(fields)
        while let first = trimmedFields.first, first.isEmpty {
            trimmedFields.removeFirst()
        }
        while let last = trimmedFields.last, last.isEmpty {
            trimmedFields.removeLast()
        }

        let label = trimmedFields.joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}

struct HrrrPressureIdxInventoryRecord: Sendable, Equatable {
    let messageNumber: Int
    let byteOffset: Int64
    let dateRunToken: String?
    let variableToken: String
    let levelText: String
    let forecastLabel: String?
    let rawLine: String
}
