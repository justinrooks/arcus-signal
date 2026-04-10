import Fluent
import Foundation
import Vapor

public enum OperatorDashboardSnapshotStoreConstants {
    public static let snapshotID = "current"
}

public protocol OperatorDashboardSnapshotStore: Sendable {
    func load(on database: any Database) async throws -> OperatorDashboardStoredSnapshot?
    func save(_ snapshot: OperatorDashboardStoredSnapshot, on database: any Database) async throws
}

public struct DatabaseOperatorDashboardSnapshotStore: OperatorDashboardSnapshotStore {
    public init() {}

    public func load(on database: any Database) async throws -> OperatorDashboardStoredSnapshot? {
        guard let model = try await OperatorDashboardSnapshotModel
            .find(OperatorDashboardSnapshotStoreConstants.snapshotID, on: database)
        else {
            return nil
        }

        if model.snapshot.schemaVersion < OperatorDashboardStoredSnapshot.currentSchemaVersion {
            let upgraded = try await upgradeLegacySnapshot(model.snapshot, on: database)
            model.snapshot = upgraded
            try await model.update(on: database)
            return upgraded
        }

        return model.snapshot
    }

    public func save(_ snapshot: OperatorDashboardStoredSnapshot, on database: any Database) async throws {
        if let existing = try await OperatorDashboardSnapshotModel.find(
            OperatorDashboardSnapshotStoreConstants.snapshotID,
            on: database
        ) {
            existing.snapshot = snapshot
            try await existing.update(on: database)
            return
        }

        let created = OperatorDashboardSnapshotModel(snapshot: snapshot)
        try await created.create(on: database)
    }

    private func upgradeLegacySnapshot(
        _ snapshot: OperatorDashboardStoredSnapshot,
        on database: any Database
    ) async throws -> OperatorDashboardStoredSnapshot {
        var detailsBySeriesID: [UUID: TouchedSeriesBackfillDetails] = [:]

        for entry in snapshot.touchedSeries where entry.ugcCodes.isEmpty || entry.tornadoDetection == nil || entry.tornadoDamageThreat == nil {
            if let series = try await ArcusSeriesModel.find(entry.seriesID, on: database) {
                detailsBySeriesID[entry.seriesID] = .init(
                    ugcCodes: series.ugcCodes,
                    tornadoDetection: series.tornadoDetection,
                    tornadoDamageThreat: series.tornadoDamageThreat
                )
            }
        }

        return backfillTouchedSeriesFields(in: snapshot, detailsBySeriesID: detailsBySeriesID)
    }
}

struct TouchedSeriesBackfillDetails: Sendable {
    let ugcCodes: [String]
    let tornadoDetection: String?
    let tornadoDamageThreat: String?
}

func backfillTouchedSeriesFields(
    in snapshot: OperatorDashboardStoredSnapshot,
    detailsBySeriesID: [UUID: TouchedSeriesBackfillDetails]
) -> OperatorDashboardStoredSnapshot {
    var upgraded = snapshot
    upgraded.touchedSeries = upgraded.touchedSeries.map { entry in
        guard let details = detailsBySeriesID[entry.seriesID] else {
            return entry
        }

        var updatedEntry = entry
        if updatedEntry.ugcCodes.isEmpty {
            updatedEntry.ugcCodes = details.ugcCodes
        }
        if updatedEntry.tornadoDetection == nil {
            updatedEntry.tornadoDetection = details.tornadoDetection
        }
        if updatedEntry.tornadoDamageThreat == nil {
            updatedEntry.tornadoDamageThreat = details.tornadoDamageThreat
        }
        return updatedEntry
    }
    upgraded.schemaVersion = OperatorDashboardStoredSnapshot.currentSchemaVersion
    return upgraded
}

private struct OperatorDashboardSnapshotStoreKey: StorageKey {
    typealias Value = any OperatorDashboardSnapshotStore
}

public extension Application {
    var operatorDashboardSnapshotStore: any OperatorDashboardSnapshotStore {
        get {
            storage[OperatorDashboardSnapshotStoreKey.self] ?? DatabaseOperatorDashboardSnapshotStore()
        }
        set {
            storage[OperatorDashboardSnapshotStoreKey.self] = newValue
        }
    }
}
