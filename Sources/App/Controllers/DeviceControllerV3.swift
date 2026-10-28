import ArcusCore
import Fluent
import Vapor

extension DeviceController {
    func createPreferencesV3(req: Request) async throws -> DevicePreferencesV3AcceptedResponse {
        let payload: DevicePreferencesV3Payload = try decodeV3(req)
        guard let id = UUID(uuidString: payload.installationId),
              let platform = Platform(rawValue: payload.platform),
              let auth = LocationAuth(rawValue: payload.consent.locationAuthorization.rawValue),
              !payload.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !payload.buildNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Invalid installation metadata")
        }
        let now = Date()
        let result = try await req.db.transaction { database in
            try await authorize(req, installationID: id, authenticated: true, v3: true, on: database)
            let existing = try await DeviceInstallationModel.find(id, on: database)
            let presence = try await DevicePresenceModel.find(id, on: database)
            let previous = PresenceReconciliationState(installation: existing, presence: presence)
            let status: DevicePreferencesV3AcceptedResponse.Status
            if let existing, let revision = existing.consentRevision {
                if payload.consentRevision < revision {
                    return (try preferenceResponse(.stale, installation: existing, now: now, app: req.application), Optional<PresenceReconciliationHandoffRequest>.none)
                }
                if payload.consentRevision == revision {
                    guard existing.consentSnapshotV3 == payload.consent else {
                        throw Abort(.conflict, reason: "Conflicting consent at accepted revision")
                    }
                    status = .unchanged
                } else { status = .accepted }
            } else { status = .accepted }

            let installation = existing ?? DeviceInstallationModel(
                installationId: id, apnsDeviceToken: "", apnsEnvironment: .sandbox,
                platform: platform, osVersion: payload.osVersion, appVersion: payload.appVersion,
                buildNumber: payload.buildNumber, locationAuth: auth)
            installation.isSubscribed = payload.consent.isSubscribed
            installation.mesoNotificationsEnabled = payload.consent.mesoNotificationsEnabled
            installation.locationSharingEnabled = payload.consent.locationSharingEnabled
            installation.locationAuth = auth
            installation.consentRevision = payload.consentRevision
            // Binding is independent of consent equality. A nil token preserves token AND environment.
            if let token = payload.apnsDeviceToken {
                installation.apnsDeviceToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
                installation.apnsEnvironmentRaw = payload.apnsEnvironment.rawValue
            }
            installation.platform = platform
            installation.osVersion = payload.osVersion
            installation.appVersion = payload.appVersion
            installation.buildNumber = payload.buildNumber
            installation.lastSeenAt = now
            installation.isActive = true
            try await installation.save(on: database)
            let handoff: PresenceReconciliationHandoffRequest?
            if let presence {
                handoff = try await reconcileDevicePresence(installationID: id, previous: previous,
                    installation: installation, presence: presence, receivedAt: now, on: database)
            } else { handoff = nil }
            return (try preferenceResponse(status, installation: installation, now: now, app: req.application), handoff)
        }
        await handoffV3(result.1, req: req)
        return result.0
    }

    func createLocationV3(req: Request) async throws -> LocationSnapshotAcceptedResponse {
        let payload: DeviceLocationSnapshotV3Payload = try decodeV3(req)
        let now = Date()
        guard let id = UUID(uuidString: payload.installationId),
              let scheme = CellScheme(rawValue: payload.cellScheme),
              payload.h3Cell.map({ $0 > 0 }) ?? true,
              payload.capturedAt <= now.addingTimeInterval(300) else {
            throw Abort(.badRequest, reason: "Invalid location observation")
        }
        let result = try await req.db.transaction { database in
            let installation = try await initializedV3(req, id: id, on: database)
            guard installation.locationSharingEnabled,
                  installation.locationAuth == .always || installation.locationAuth == .whenInUse else {
                return ("ignored", Optional<PresenceReconciliationHandoffRequest>.none)
            }
            let previous = PresenceReconciliationState(installation: installation,
                presence: try await DevicePresenceModel.find(id, on: database))
            let outcome = try await upsertDevicePresence(installationId: id, payload: payload,
                cellScheme: scheme, locationSource: payload.source, receivedAt: now, on: database)
            guard outcome != .staleIgnored,
                  let presence = try await DevicePresenceModel.find(id, on: database) else {
                return ("stale", Optional<PresenceReconciliationHandoffRequest>.none)
            }
            let handoff = try await reconcileDevicePresence(installationID: id, previous: previous,
                installation: installation, presence: presence, receivedAt: now, on: database)
            return ("accepted", handoff)
        }
        await handoffV3(result.1, req: req)
        return .init(status: result.0, receivedAt: now)
    }

    func createActivityV3(req: Request) async throws -> HTTPStatus {
        let payload = try req.content.decode(ForegroundActivityRequest.self)
        try await req.db.transaction { database in
            _ = try await initializedV3(req, id: payload.installationId, on: database)
            try await InstallationActivityDailyStore().record(installationID: payload.installationId, receivedAt: .now, on: database)
        }
        return .noContent
    }
}

private func decodeV3<T: Content>(_ req: Request) throws -> T {
    do { return try req.content.decode(T.self) }
    catch { throw Abort(.badRequest, reason: "Invalid v3 device payload") }
}

private func initializedV3(_ req: Request, id: UUID, on database: any Database) async throws -> DeviceInstallationModel {
    try await authorize(req, installationID: id, authenticated: true, v3: true, on: database)
    guard let installation = try await DeviceInstallationModel.find(id, on: database), installation.consentRevision != nil else {
        throw Abort(.conflict, reason: "Initial v3 consent required")
    }
    return installation
}

private func preferenceResponse(_ status: DevicePreferencesV3AcceptedResponse.Status,
    installation: DeviceInstallationModel, now: Date, app: Application
) throws -> DevicePreferencesV3AcceptedResponse {
    guard let revision = installation.consentRevision else { throw Abort(.internalServerError) }
    return try .init(status: status, acceptedConsentRevision: revision, receivedAt: now,
        serverOwnsMesoNotificationDelivery: app.mesoNotificationsEnabled && installation.isActive
            && installation.isSubscribed && installation.mesoNotificationsEnabled == true
            && installation.locationSharingEnabled && !installation.apnsDeviceToken.isEmpty
            && (installation.locationAuth == .always || installation.locationAuth == .whenInUse))
}

private func handoffV3(_ handoff: PresenceReconciliationHandoffRequest?, req: Request) async {
    guard let handoff else { return }
    await req.application.presenceReconciliationHandoff.handoff(handoff, on: req.application, database: req.db, logger: req.logger)
}

extension DeviceInstallationModel {
    var consentSnapshotV3: DeviceConsentSnapshotV3 {
        .init(isSubscribed: isSubscribed, mesoNotificationsEnabled: mesoNotificationsEnabled == true,
              locationSharingEnabled: locationSharingEnabled,
              locationAuthorization: .init(rawValue: locationAuthRaw) ?? .unknown)
    }
}
