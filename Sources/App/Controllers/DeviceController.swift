//
//  DeviceController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/28/26.
//

import Fluent
import Vapor
import ArcusCore

private enum DevicePresenceUpsertOutcome: String {
    case inserted
    case updated
    case staleIgnored
}

private struct DevicePresenceCommitResult {
    let outcome: DevicePresenceUpsertOutcome
    let reconciliationHandoff: PresenceReconciliationHandoffRequest?
}

struct DeviceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            let devices = root.grouped("v1", "devices")
            devices.get(use: index)
            devices.post("location-snapshots", use: create)
            devices.post("preferences", use: createPreferences)
        }
    }
    
    func create(req: Request) async throws -> LocationSnapshotAcceptedResponse {
        let payload = try req.content.decode(LocationSnapshotPushPayload.self)
        let installationId = payload.installationId
        guard let installationUUID = UUID(uuidString: installationId) else {
            throw Abort(.badRequest, reason: "installationId must be a valid UUID")
        }
        let apnsDeviceToken = payload.apnsDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Validate enums
        guard let apnsEnvironment = APNsEnvironment(rawValue: payload.apnsEnvironment) else {
            throw Abort(.badRequest, reason: "Invalid enum value for apnsEnvironment")
        }
        guard let platform = Platform(rawValue: payload.platform) else {
            throw Abort(.badRequest, reason: "Invalid enum value for platform")
        }
        guard let locationAuth = LocationAuth(rawValue: payload.auth) else {
            throw Abort(.badRequest, reason: "Invalid enum value for locationAuth")
        }
        guard let cellScheme = CellScheme(rawValue: payload.cellScheme) else {
            throw Abort(.badRequest, reason: "Invalid enum value for cellScheme")
        }
        guard let locationSource = LocationUploadSource(rawValue: payload.source) else {
            throw Abort(.badRequest, reason: "Invalid enum value for locationSource")
        }
        
        // Validate required identifiers
        guard !apnsDeviceToken.isEmpty else {
            throw Abort(.badRequest, reason: "Missing apnsDeviceToken")
        }
        guard !payload.osVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Missing osVersion")
        }
        guard !payload.appVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Missing appVersion")
        }
        guard !payload.buildNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Missing buildNumber")
        }
        
        // Validate numeric bounds
        guard payload.locationAgeSeconds >= 0 else {
            throw Abort(.badRequest, reason: "locationAgeSeconds must be >= 0")
        }
        guard payload.horizontalAccuracyMeters >= 0 else {
            throw Abort(.badRequest, reason: "horizontalAccuracyMeters must be >= 0")
        }
        if let h3Cell = payload.h3Cell, h3Cell <= 0 {
            throw Abort(.badRequest, reason: "h3Cell must be > 0 when provided")
        }
        
        // Validate h3 fields as a pair
        let hasH3Cell = payload.h3Cell != nil
        let hasH3Resolution = payload.h3Resolution != nil
        guard hasH3Cell == hasH3Resolution else {
            throw Abort(.badRequest, reason: "h3Cell and h3Resolution must both be set or both be null")
        }
        
        if let h3Resolution = payload.h3Resolution, !(0...15).contains(h3Resolution) {
            throw Abort(.badRequest, reason: "h3Resolution must be between 0 and 15")
        }
        
        let receivedAt = Date()
        guard payload.capturedAt <= receivedAt.addingTimeInterval(300) else {
            throw Abort(.badRequest, reason: "capturedAt cannot be more than 5 minutes in the future")
        }
        
        // Validate cross-field consistency
        switch cellScheme {
        case .h3:
            guard hasH3Cell, hasH3Resolution else {
                throw Abort(.badRequest, reason: "cellScheme=h3 requires h3Cell and h3Resolution")
            }
        case .ugcOnly:
            // No-op for now, to allow partial payloads while preserving previously known h3 fields.
            break
        }
        
        let commitResult = try await req.db.transaction { database in
            let previousInstallation = try await DeviceInstallationModel.find(installationUUID, on: database)
            let previousPresence = try await DevicePresenceModel.find(installationUUID, on: database)
            let previousState = PresenceReconciliationState(
                installation: previousInstallation,
                presence: previousPresence
            )

            let installation = try await upsertDeviceInstallation(
                installationId: installationUUID,
                apnsDeviceToken: apnsDeviceToken,
                apnsEnvironment: apnsEnvironment,
                platform: platform,
                osVersion: payload.osVersion,
                appVersion: payload.appVersion,
                buildNumber: payload.buildNumber,
                locationAuth: locationAuth,
                lastSeenAt: receivedAt,
                isSubscribed: payload.isSubscribed ?? true,
                on: database
            )
            
            let presenceOutcome = try await upsertDevicePresence(
                installationId: installationUUID,
                payload: payload,
                cellScheme: cellScheme,
                locationSource: locationSource,
                receivedAt: receivedAt,
                on: database
            )

            guard presenceOutcome != .staleIgnored,
                  let presence = try await DevicePresenceModel.find(installationUUID, on: database) else {
                return DevicePresenceCommitResult(outcome: presenceOutcome, reconciliationHandoff: nil)
            }

            guard let currentState = PresenceReconciliationState(
                installation: installation,
                presence: presence
            ) else {
                return DevicePresenceCommitResult(outcome: presenceOutcome, reconciliationHandoff: nil)
            }
            var reconciliationHandoff: PresenceReconciliationHandoffRequest?
            if let trigger = PresenceReconciliationTrigger.decide(
                previous: previousState,
                current: currentState,
                now: receivedAt
            ) {
                let insertResult = try await PresenceReconciliationOutboxStore().insert(
                    installationID: installationUUID,
                    presenceCapturedAt: presence.capturedAt,
                    triggerCategory: trigger.category,
                    targetingFingerprint: try StableContentHasher.sha256Hex(of: currentState.fingerprint),
                    on: database
                )
                if let intentId = insertResult.id {
                    reconciliationHandoff = .init(
                        intentId: intentId,
                        installationId: installationUUID,
                        triggerCategory: trigger.category,
                        priorAttemptCount: 0
                    )
                }
            }

            return DevicePresenceCommitResult(
                outcome: presenceOutcome,
                reconciliationHandoff: reconciliationHandoff
            )
        }

        if let reconciliationHandoff = commitResult.reconciliationHandoff {
            await req.application.presenceReconciliationHandoff.handoff(
                reconciliationHandoff,
                on: req.application,
                database: req.db,
                logger: req.logger
            )
        }
        
        // Avoid logging full APNS token in production logs.
        req.logger.info(
            "Device heartbeat received.",
            metadata: [
                "capturedAt": .string(String(reflecting: payload.capturedAt)),
                "locationAgeSeconds": .string(String(reflecting: payload.locationAgeSeconds)),
                "horizontalAccuracyMeters": .string(String(reflecting: payload.horizontalAccuracyMeters)),
                "cellScheme": .string(payload.cellScheme),
                "h3Cell": .string(String(reflecting: payload.h3Cell)),
                "h3Resolution": .string(String(reflecting: payload.h3Resolution)),
                "county": .string(payload.county ?? "N/A"),
                "zone": .string(payload.zone ?? "N/A"),
                "fireZone": .string(payload.fireZone ?? "N/A"),
                "apnsDeviceTokenSuffix": .string(String(apnsDeviceToken.suffix(8))),
                "installationId": .string(installationId),
                "source": .string(payload.source),
                "auth": .string(payload.auth),
                "appVersion": .string(payload.appVersion),
                "buildNumber": .string(payload.buildNumber),
                "platform": .string(payload.platform),
                "osVersion": .string(payload.osVersion),
                "apnsEnvironment": .string(payload.apnsEnvironment),
                "presenceOutcome": .string(commitResult.outcome.rawValue)
            ]
        )
        
        return .init(status: "ok", receivedAt: receivedAt)
    }
    
    func index(req: Request) async throws -> Response {
        return .init(status: .custom(code: 200, reasonPhrase: "fetch the devices"))
        
        //        devices.group(":id") { device in
        //            app.get("hello", ":name") { req -> String in
        //        let name = req.parameters.get("name")!
        //        return "Hello, \(name)!"
        //    }
        //        }
        //        }
    }

    func createPreferences(req: Request) async throws -> DevicePreferenceSyncAcceptedResponse {
        let payload = try req.content.decode(DevicePreferenceSyncPayload.self)

        guard let installationUUID = UUID(uuidString: payload.installationId) else {
            throw Abort(.badRequest, reason: "installationId must be a valid UUID")
        }

        let apnsDeviceToken = payload.apnsDeviceToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apnsDeviceToken.isEmpty else {
            throw Abort(.badRequest, reason: "Missing apnsDeviceToken")
        }

        guard let apnsEnvironment = APNsEnvironment(rawValue: payload.apnsEnvironment) else {
            throw Abort(.badRequest, reason: "Invalid enum value for apnsEnvironment")
        }
        guard let platform = Platform(rawValue: payload.platform) else {
            throw Abort(.badRequest, reason: "Invalid enum value for platform")
        }
        guard let locationAuth = LocationAuth(rawValue: payload.auth) else {
            throw Abort(.badRequest, reason: "Invalid enum value for locationAuth")
        }

        let osVersion = payload.osVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let appVersion = payload.appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildNumber = payload.buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !osVersion.isEmpty else {
            throw Abort(.badRequest, reason: "Missing osVersion")
        }
        guard !appVersion.isEmpty else {
            throw Abort(.badRequest, reason: "Missing appVersion")
        }
        guard !buildNumber.isEmpty else {
            throw Abort(.badRequest, reason: "Missing buildNumber")
        }

        let receivedAt = Date()

        _ = try await req.db.transaction { database in
            try await upsertDeviceInstallation(
                installationId: installationUUID,
                apnsDeviceToken: apnsDeviceToken,
                apnsEnvironment: apnsEnvironment,
                platform: platform,
                osVersion: osVersion,
                appVersion: appVersion,
                buildNumber: buildNumber,
                locationAuth: locationAuth,
                lastSeenAt: receivedAt,
                isSubscribed: payload.isSubscribed,
                on: database
            )
        }

        req.logger.info(
            "Device preferences synced.",
            metadata: [
                "installationId": .string(payload.installationId),
                "apnsDeviceTokenSuffix": .string(String(apnsDeviceToken.suffix(8))),
                "apnsEnvironment": .string(payload.apnsEnvironment),
                "platform": .string(payload.platform),
                "auth": .string(payload.auth),
                "isSubscribed": .string(String(payload.isSubscribed)),
                "source": .string(payload.source),
                "reason": .string(payload.reason)
            ]
        )

        return .init(status: "ok", receivedAt: receivedAt)
    }
}

private func upsertDeviceInstallation(
    installationId: UUID,
    apnsDeviceToken: String,
    apnsEnvironment: APNsEnvironment,
    platform: Platform,
    osVersion: String,
    appVersion: String,
    buildNumber: String,
    locationAuth: LocationAuth,
    lastSeenAt: Date,
    isSubscribed: Bool,
    on database: any Database
) async throws -> DeviceInstallationModel {
    if let existing = try await DeviceInstallationModel.find(installationId, on: database) {
        existing.apnsDeviceToken = apnsDeviceToken
        existing.apnsEnvironment = apnsEnvironment
        existing.platform = platform
        existing.osVersion = osVersion
        existing.appVersion = appVersion
        existing.buildNumber = buildNumber
        existing.locationAuth = locationAuth
        existing.isActive = true
        existing.isSubscribed = isSubscribed
        existing.lastSeenAt = lastSeenAt
        try await existing.update(on: database)
        return existing
    }
    
    let created = DeviceInstallationModel(
        installationId: installationId,
        apnsDeviceToken: apnsDeviceToken,
        apnsEnvironment: apnsEnvironment,
        platform: platform,
        osVersion: osVersion,
        appVersion: appVersion,
        buildNumber: buildNumber,
        locationAuth: locationAuth,
        isActive: true,
        lastSeenAt: lastSeenAt,
        isSubscribed: isSubscribed
    )
    
    do {
        try await created.create(on: database)
        return created
    } catch {
        guard DbUtils.isUniqueConstraintViolation(error),
              let existing = try await DeviceInstallationModel.find(installationId, on: database) else {
            throw error
        }
        
        existing.apnsDeviceToken = apnsDeviceToken
        existing.apnsEnvironment = apnsEnvironment
        existing.platform = platform
        existing.osVersion = osVersion
        existing.appVersion = appVersion
        existing.buildNumber = buildNumber
        existing.locationAuth = locationAuth
        existing.isActive = true
        existing.lastSeenAt = lastSeenAt
        existing.isSubscribed = isSubscribed
        try await existing.update(on: database)
        return existing
    }
}

private func upsertDevicePresence(
    installationId: UUID,
    payload: LocationSnapshotPushPayload,
    cellScheme: CellScheme,
    locationSource: LocationUploadSource,
    receivedAt: Date,
    on database: any Database
) async throws -> DevicePresenceUpsertOutcome {
    if let existing = try await DevicePresenceModel.find(installationId, on: database) {
        guard payload.capturedAt >= existing.capturedAt else {
            return .staleIgnored
        }
        
        existing.capturedAt = payload.capturedAt
        existing.receivedAt = receivedAt
        existing.locationAgeSeconds = payload.locationAgeSeconds
        existing.horizontalAccuracyMeters = payload.horizontalAccuracyMeters
        existing.cellScheme = cellScheme
        existing.source = locationSource
        
        if let h3Cell = payload.h3Cell {
            existing.h3Cell = h3Cell
        }
        if let h3Resolution = payload.h3Resolution {
            existing.h3Resolution = h3Resolution
        }
        if let county = normalizedOptional(payload.county) {
            existing.county = county
        }
        if let zone = normalizedOptional(payload.zone) {
            existing.zone = zone
        }
        if let fireZone = normalizedOptional(payload.fireZone) {
            existing.fireZone = fireZone
        }
        if let countyLabel = payload.countyLabel {
            existing.countyLabel = countyLabel
        }
        if let fireZoneLabel = payload.fireZoneLabel {
            existing.fireZoneLabel = fireZoneLabel
        }
        
        try await existing.update(on: database)
        return .updated
    }
    
    let created = DevicePresenceModel(
        installationId: installationId,
        capturedAt: payload.capturedAt,
        receivedAt: receivedAt,
        locationAgeSeconds: payload.locationAgeSeconds,
        horizontalAccuracyMeters: payload.horizontalAccuracyMeters,
        cellScheme: cellScheme,
        h3Cell: payload.h3Cell,
        h3Resolution: payload.h3Resolution,
        county: normalizedOptional(payload.county),
        zone: normalizedOptional(payload.zone),
        fireZone: normalizedOptional(payload.fireZone),
        source: locationSource,
        countyLabel: payload.countyLabel,
        fireZoneLabel: payload.fireZoneLabel
    )
    
    do {
        try await created.create(on: database)
        return .inserted
    } catch {
        guard DbUtils.isUniqueConstraintViolation(error),
              let existing = try await DevicePresenceModel.find(installationId, on: database) else {
            throw error
        }
        
        guard payload.capturedAt >= existing.capturedAt else {
            return .staleIgnored
        }
        
        existing.capturedAt = payload.capturedAt
        existing.receivedAt = receivedAt
        existing.locationAgeSeconds = payload.locationAgeSeconds
        existing.horizontalAccuracyMeters = payload.horizontalAccuracyMeters
        existing.cellScheme = cellScheme
        existing.source = locationSource
        
        if let h3Cell = payload.h3Cell {
            existing.h3Cell = h3Cell
        }
        if let h3Resolution = payload.h3Resolution {
            existing.h3Resolution = h3Resolution
        }
        if let county = normalizedOptional(payload.county) {
            existing.county = county
        }
        if let zone = normalizedOptional(payload.zone) {
            existing.zone = zone
        }
        if let fireZone = normalizedOptional(payload.fireZone) {
            existing.fireZone = fireZone
        }
        if let countyLabel = payload.countyLabel {
            existing.countyLabel = countyLabel
        }
        if let fireZoneLabel = payload.fireZoneLabel {
            existing.fireZoneLabel = fireZoneLabel
        }
        
        try await existing.update(on: database)
        return .updated
    }
}
