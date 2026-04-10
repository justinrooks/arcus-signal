import Fluent
import Foundation

public final class OperatorDashboardSnapshotModel: Model, @unchecked Sendable {
    public static let schema = "operator_dashboard_snapshots"

    @ID(custom: "id", generatedBy: .user)
    public var id: String?

    @Field(key: "snapshot")
    public var snapshot: OperatorDashboardStoredSnapshot

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        id: String = OperatorDashboardSnapshotStoreConstants.snapshotID,
        snapshot: OperatorDashboardStoredSnapshot
    ) {
        self.id = id
        self.snapshot = snapshot
    }
}
