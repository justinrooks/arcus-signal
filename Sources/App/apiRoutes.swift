import Fluent
import Queues
import Vapor

// Api Routes
func configureAPIRoutes(_ app: Application) throws {

    // MARK: Health APIs
    app.group("health") { health in
        health.get() { _ in
            "ok"
        }
        // TODO: DB endpoint health?
    }
    
    // MARK: V1 Device APIs
    app.group("api", "v1", "devices") { devices in
        devices.get() { req async throws in
            "fetch the devices"
        }
        
        devices.post("location-snapshots") { req async throws -> LocationSnapshotAcceptedResponse in
            let payload = try req.content.decode(LocationSnapshotPushPayload.self)
            let installationId = payload.installationId
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
            guard let locationSource = LocationSource(rawValue: payload.source) else {
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

            let presenceOutcome = try await req.db.transaction { database in
                _ = try await upsertDeviceInstallation(
                    installationId: installationId,
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

                return try await upsertDevicePresence(
                    installationId: installationId,
                    payload: payload,
                    cellScheme: cellScheme,
                    locationSource: locationSource,
                    receivedAt: receivedAt,
                    on: database
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
                    "installationId": .string(installationId.uuidString),
                    "source": .string(payload.source),
                    "auth": .string(payload.auth),
                    "appVersion": .string(payload.appVersion),
                    "buildNumber": .string(payload.buildNumber),
                    "platform": .string(payload.platform),
                    "osVersion": .string(payload.osVersion),
                    "apnsEnvironment": .string(payload.apnsEnvironment),
                    "presenceOutcome": .string(presenceOutcome.rawValue)
                ]
            )

            return .init(status: "ok", receivedAt: receivedAt)
        }
        
//        devices.group(":id") { device in
//            app.get("hello", ":name") { req -> String in
        //        let name = req.parameters.get("name")!
        //        return "Hello, \(name)!"
        //    }
//        }
    }

    app.group("api", "v1", "dev") { dev in
        dev.post("replay-ingest") { req async throws -> Response in
            guard req.application.environment != .production else {
                throw Abort(.notFound)
            }

            let request = try req.content.decode(ReplayIngestRequest.self)
            let fixtureName = request.fixtureName.trimmingCharacters(in: .whitespacesAndNewlines)
            let runLabel = request.runLabel?.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !fixtureName.isEmpty else {
                throw Abort(.badRequest, reason: "fixtureName is required")
            }

            req.logger.info(
                "Replay ingest accepted.",
                metadata: [
                    "fixtureName": .string(fixtureName),
                    "runLabel": .string(runLabel ?? "none")
                ]
            )

            let payload = IngestNWSAlertsPayload(
                source: .fixture,
                fixtureName: fixtureName,
                runLabel: runLabel
            )
            try await req.application.queues
                .queue(ArcusQueueLane.ingest.queueName)
                .dispatch(IngestNWSAlertsJob.self, payload)

            let accepted = ReplayIngestAcceptedResponse(
                status: "accepted",
                source: IngestNWSAlertsSource.fixture.rawValue,
                fixtureName: fixtureName,
                runLabel: runLabel,
                queuedAt: Date()
            )
            let response = Response(status: .accepted)
            try response.content.encode(accepted)
            return response
        }
    }
}

private enum DevicePresenceUpsertOutcome: String {
    case inserted
    case updated
    case staleIgnored
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
        guard isUniqueConstraintViolation(error),
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
    locationSource: LocationSource,
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
        guard isUniqueConstraintViolation(error),
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

private func normalizedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

private func isUniqueConstraintViolation(_ error: any Error) -> Bool {
    let description = String(describing: error).lowercased()
    return description.contains("duplicate key value")
        || description.contains("unique constraint")
        || description.contains("23505")
}
