import Fluent
import FluentSQL
import Foundation
import Vapor

public enum NotificationMissReason: String, Codable, Sendable {
    case staleLocation = "stale_location"
}

public final class NotificationMissedDecisionModel: Model, @unchecked Sendable {
    public static let schema = "notification_missed_decisions"

    @ID(key: .id)
    public var id: UUID?

    @Parent(key: "installation_id")
    public var deviceInstallation: DeviceInstallationModel

    @Parent(key: "series_id")
    public var series: ArcusSeriesModel

    @Field(key: "revision_urn")
    public var revisionUrn: String

    @Field(key: "mode")
    public var modeRaw: String

    @Field(key: "reason")
    public var reasonRaw: String

    @Field(key: "freshness_state")
    public var freshnessStateRaw: String

    @Field(key: "miss_reason")
    public var missReasonRaw: String

    @Field(key: "permission_mode")
    public var permissionModeRaw: String

    @Field(key: "captured_at")
    public var capturedAt: Date

    @Field(key: "received_at")
    public var receivedAt: Date

    @Field(key: "evaluated_at")
    public var evaluatedAt: Date

    @Timestamp(key: "created", on: .create)
    public var created: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        installationID: UUID,
        seriesID: UUID,
        revisionUrn: String,
        mode: NotificationTargetMode,
        reason: NotificationReason,
        freshnessState: LocationFreshnessState,
        missReason: NotificationMissReason,
        permissionMode: LocationAuth,
        capturedAt: Date,
        receivedAt: Date,
        evaluatedAt: Date
    ) {
        self.id = id
        self.$deviceInstallation.id = installationID
        self.$series.id = seriesID
        self.revisionUrn = revisionUrn
        self.modeRaw = mode.rawValue
        self.reasonRaw = reason.rawValue
        self.freshnessStateRaw = freshnessState.rawValue
        self.missReasonRaw = missReason.rawValue
        self.permissionModeRaw = permissionMode.rawValue
        self.capturedAt = capturedAt
        self.receivedAt = receivedAt
        self.evaluatedAt = evaluatedAt
    }

    public var mode: NotificationTargetMode {
        get { NotificationTargetMode(rawValue: modeRaw) ?? .ugc }
        set { modeRaw = newValue.rawValue }
    }

    public var reason: NotificationReason {
        get { NotificationReason(rawValue: reasonRaw) ?? .new }
        set { reasonRaw = newValue.rawValue }
    }

    public var freshnessState: LocationFreshnessState {
        get { LocationFreshnessState(rawValue: freshnessStateRaw) ?? .stale }
        set { freshnessStateRaw = newValue.rawValue }
    }

    public var missReason: NotificationMissReason {
        get { NotificationMissReason(rawValue: missReasonRaw) ?? .staleLocation }
        set { missReasonRaw = newValue.rawValue }
    }

    public var permissionMode: LocationAuth {
        get { LocationAuth(rawValue: permissionModeRaw) ?? .unknown }
        set { permissionModeRaw = newValue.rawValue }
    }
}

struct NotificationMissedDecisionInsertResult {
    let inserted: Bool
    let id: UUID?
}

struct NotificationMissedDecisionInsertInput {
    let installationID: UUID
    let seriesID: UUID
    let revisionUrn: String
    let mode: NotificationTargetMode
    let reason: NotificationReason
    let freshnessState: LocationFreshnessState
    let missReason: NotificationMissReason
    let permissionMode: LocationAuth
    let capturedAt: Date
    let receivedAt: Date
    let evaluatedAt: Date
}

struct NotificationMissedDecisionStore {
    func insertStaleMissDecision(
        _ input: NotificationMissedDecisionInsertInput,
        on db: any Database
    ) async throws -> NotificationMissedDecisionInsertResult {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        let newID = UUID()
        let row = try await sql.raw("""
            INSERT INTO notification_missed_decisions
                (id, installation_id, series_id, revision_urn, mode, reason, freshness_state, miss_reason,
                 permission_mode, captured_at, received_at, evaluated_at, created)
            VALUES
                (\(bind: newID),
                 \(bind: input.installationID),
                 \(bind: input.seriesID),
                 \(bind: input.revisionUrn),
                 \(bind: input.mode),
                 \(bind: input.reason),
                 \(bind: input.freshnessState),
                 \(bind: input.missReason),
                 \(bind: input.permissionMode),
                 \(bind: input.capturedAt),
                 \(bind: input.receivedAt),
                 \(bind: input.evaluatedAt),
                 NOW())
            ON CONFLICT (installation_id, series_id, revision_urn, mode, reason, miss_reason)
            DO NOTHING
            RETURNING id
            """)
            .first()

        if let row {
            let insertedID = try row.decode(column: "id", as: UUID.self)
            return .init(inserted: true, id: insertedID)
        }

        return .init(inserted: false, id: nil)
    }
}
