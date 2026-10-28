import ArcusCore
import Fluent
import Vapor

/// The shared geographic merge seam has no access to consent or delivery binding.
protocol DevicePresenceSnapshot {
    var capturedAt: Date { get }
    var locationAgeSeconds: Double { get }
    var horizontalAccuracyMeters: Double { get }
    var h3Cell: Int64? { get }
    var h3Resolution: Int? { get }
    var county: String? { get }
    var zone: String? { get }
    var fireZone: String? { get }
    var countyLabel: String? { get }
    var fireZoneLabel: String? { get }
}
extension LocationSnapshotPushPayload: DevicePresenceSnapshot {}
extension DeviceLocationSnapshotV3Payload: DevicePresenceSnapshot {}

func reconcileDevicePresence(
    installationID: UUID, previous: PresenceReconciliationState?,
    installation: DeviceInstallationModel, presence: DevicePresenceModel,
    receivedAt: Date, on database: any Database
) async throws -> PresenceReconciliationHandoffRequest? {
    guard let current = PresenceReconciliationState(installation: installation, presence: presence),
          let trigger = PresenceReconciliationTrigger.decide(previous: previous, current: current, now: receivedAt) else { return nil }
    let result = try await PresenceReconciliationOutboxStore().insert(
        installationID: installationID, presenceCapturedAt: presence.capturedAt,
        triggerCategory: trigger.category,
        targetingFingerprint: try StableContentHasher.sha256Hex(of: current.fingerprint), on: database)
    guard let id = result.id else { return nil }
    return .init(intentId: id, installationId: installationID, triggerCategory: trigger.category, priorAttemptCount: 0)
}
