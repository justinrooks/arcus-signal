import Foundation

struct HrrrPressureProfileMessageSelector: Sendable {
    private let preferredLevels: [StormSetupPressureLevel]
    private let requiredVariables: [StormSetupPressureProfileVariable]

    init(
        preferredLevels: [StormSetupPressureLevel] = StormSetupPressureLevel.preferredDescending,
        requiredVariables: [StormSetupPressureProfileVariable] = [.hgt, .tmp, .dpt, .ugrd, .vgrd]
    ) {
        self.preferredLevels = preferredLevels
        self.requiredVariables = requiredVariables
    }

    func select(inventory: HrrrPressureIdxInventory) -> HrrrPressureProfileMessageSelectionResult {
        let preferredLevelSet = Set(preferredLevels)
        var draftsByLevel: [StormSetupPressureLevel: PressureLevelDraft] = [:]
        var ignoredRecords: [HrrrPressureProfileIgnoredRecord] = []

        for (inventoryIndex, record) in inventory.records.enumerated() {
            guard let variable = normalizePressureProfileVariableToken(record.variableToken) else {
                ignoredRecords.append(
                    HrrrPressureProfileIgnoredRecord(
                        inventoryIndex: inventoryIndex,
                        rawLine: record.rawLine,
                        reason: .unsupportedVariable(record.variableToken)
                    )
                )
                continue
            }

            guard let level = StormSetupPressureLevel.parse(from: record.levelText) else {
                ignoredRecords.append(
                    HrrrPressureProfileIgnoredRecord(
                        inventoryIndex: inventoryIndex,
                        rawLine: record.rawLine,
                        reason: .unsupportedPressureLevel(record.levelText)
                    )
                )
                continue
            }

            guard preferredLevelSet.contains(level) else {
                ignoredRecords.append(
                    HrrrPressureProfileIgnoredRecord(
                        inventoryIndex: inventoryIndex,
                        rawLine: record.rawLine,
                        reason: .unsupportedPressureLevel(record.levelText)
                    )
                )
                continue
            }

            var draft = draftsByLevel[level] ?? PressureLevelDraft(pressureLevel: level)
            draft.record(
                inventoryIndex: inventoryIndex,
                record: record,
                variable: variable
            )
            draftsByLevel[level] = draft
        }

        var selectedMessages: [HrrrPressureProfileSelectedMessage] = []
        var missingLevels: [StormSetupPressureProfileMissingLevel] = []

        for level in preferredLevels {
            guard let draft = draftsByLevel[level] else {
                missingLevels.append(
                    StormSetupPressureProfileMissingLevel(
                        pressureMb: level.pressureMb,
                        missingVariables: requiredVariables
                    )
                )
                continue
            }

            let missingVariables = draft.missingVariables(requiredVariables: requiredVariables)
            guard missingVariables.isEmpty else {
                missingLevels.append(
                    StormSetupPressureProfileMissingLevel(
                        pressureMb: level.pressureMb,
                        missingVariables: missingVariables
                    )
                )
                continue
            }

            selectedMessages.append(
                contentsOf: draft.selectedMessages(requiredVariables: requiredVariables)
            )
        }

        selectedMessages.sort(by: { $0.inventoryIndex < $1.inventoryIndex })

        return HrrrPressureProfileMessageSelectionResult(
            requestedLevels: preferredLevels,
            selectedMessages: selectedMessages,
            missingLevels: missingLevels,
            ignoredRecords: ignoredRecords
        )
    }
}

struct HrrrPressureProfileMessageSelectionResult: Sendable, Equatable {
    let requestedLevels: [StormSetupPressureLevel]
    let selectedMessages: [HrrrPressureProfileSelectedMessage]
    let missingLevels: [StormSetupPressureProfileMissingLevel]
    let ignoredRecords: [HrrrPressureProfileIgnoredRecord]
}

struct HrrrPressureProfileSelectedMessage: Sendable, Equatable {
    let inventoryIndex: Int
    let record: HrrrPressureIdxInventoryRecord
    let pressureLevel: StormSetupPressureLevel
    let variable: StormSetupPressureProfileVariable
}

struct HrrrPressureProfileIgnoredRecord: Sendable, Equatable {
    let inventoryIndex: Int
    let rawLine: String
    let reason: HrrrPressureProfileIgnoredRecordReason
}

enum HrrrPressureProfileIgnoredRecordReason: Sendable, Equatable {
    case unsupportedVariable(String)
    case unsupportedPressureLevel(String)
}

fileprivate struct PressureLevelDraft: Sendable {
    let pressureLevel: StormSetupPressureLevel
    private var firstRecordByVariable: [StormSetupPressureProfileVariable: IndexedRecord] = [:]

    init(pressureLevel: StormSetupPressureLevel) {
        self.pressureLevel = pressureLevel
    }

    mutating func record(
        inventoryIndex: Int,
        record: HrrrPressureIdxInventoryRecord,
        variable: StormSetupPressureProfileVariable
    ) {
        guard firstRecordByVariable[variable] == nil else {
            return
        }

        firstRecordByVariable[variable] = IndexedRecord(
            inventoryIndex: inventoryIndex,
            record: record
        )
    }

    func missingVariables(
        requiredVariables: [StormSetupPressureProfileVariable]
    ) -> [StormSetupPressureProfileVariable] {
        requiredVariables.filter { firstRecordByVariable[$0] == nil }
    }

    func selectedMessages(
        requiredVariables: [StormSetupPressureProfileVariable]
    ) -> [HrrrPressureProfileSelectedMessage] {
        requiredVariables.compactMap { variable in
            guard let indexedRecord = firstRecordByVariable[variable] else {
                return nil
            }

            return HrrrPressureProfileSelectedMessage(
                inventoryIndex: indexedRecord.inventoryIndex,
                record: indexedRecord.record,
                pressureLevel: pressureLevel,
                variable: variable
            )
        }
    }
}

fileprivate struct IndexedRecord: Sendable, Equatable {
    let inventoryIndex: Int
    let record: HrrrPressureIdxInventoryRecord
}

private func normalizePressureProfileVariableToken(_ token: String) -> StormSetupPressureProfileVariable? {
    let normalized = token
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .uppercased()
    return StormSetupPressureProfileVariable(rawValue: normalized)
}
