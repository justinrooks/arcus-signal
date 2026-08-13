import Fluent
import Foundation

enum PresenceReconciliationOutboxState: String, Codable, Sendable {
    case ready
    case done
    case dead
}

final class PresenceReconciliationOutboxModel: Model, @unchecked Sendable {
    static let schema = "presence_reconciliation_outbox"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "installation_id")
    var installation: DeviceInstallationModel

    @Field(key: "presence_captured_at")
    var presenceCapturedAt: Date

    @Field(key: "trigger_category")
    var triggerCategoryRaw: String

    @Field(key: "targeting_fingerprint")
    var targetingFingerprint: String

    @Field(key: "state")
    var stateRaw: String

    @Field(key: "attempt_count")
    var attemptCount: Int

    @OptionalField(key: "last_error")
    var lastError: String?

    @Field(key: "available_at")
    var availableAt: Date

    @OptionalField(key: "dispatched_at")
    var dispatchedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        installationID: UUID,
        presenceCapturedAt: Date,
        triggerCategory: PresenceReconciliationTriggerCategory,
        targetingFingerprint: String,
        state: PresenceReconciliationOutboxState = .ready,
        attemptCount: Int = 0,
        lastError: String? = nil,
        availableAt: Date = .now,
        dispatchedAt: Date? = nil
    ) {
        self.id = id
        self.$installation.id = installationID
        self.presenceCapturedAt = presenceCapturedAt
        self.triggerCategoryRaw = triggerCategory.rawValue
        self.targetingFingerprint = targetingFingerprint
        self.stateRaw = state.rawValue
        self.attemptCount = attemptCount
        self.lastError = lastError
        self.availableAt = availableAt
        self.dispatchedAt = dispatchedAt
    }
}

extension PresenceReconciliationOutboxModel {
    var triggerCategory: PresenceReconciliationTriggerCategory {
        get { PresenceReconciliationTriggerCategory(rawValue: triggerCategoryRaw) ?? .firstUsablePresence }
        set { triggerCategoryRaw = newValue.rawValue }
    }

    var state: PresenceReconciliationOutboxState {
        get { PresenceReconciliationOutboxState(rawValue: stateRaw) ?? .ready }
        set { stateRaw = newValue.rawValue }
    }
}
