//
//  DeviceInstallation.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/4/26.
//

import Fluent
import Foundation
import Vapor

public final class DeviceInstallationModel: Model, @unchecked Sendable {
    public static let schema = "device_installations"
    
    // Primary key: installation_id (UUID)
    @ID(custom: "installation_id", generatedBy: .user)
    public var id: UUID?

    // Delivery
    @Field(key: "apns_device_token")
    public var apnsDeviceToken: String

    @Field(key: "apns_environment")
    public var apnsEnvironmentRaw: String

    // Client metadata
    @Field(key: "platform")
    public var platformRaw: String

    @Field(key: "os_version")
    public var osVersion: String

    @Field(key: "app_version")
    public var appVersion: String

    @Field(key: "build_number")
    public var buildNumber: String

    // Location capability context
    @Field(key: "location_auth")
    public var locationAuthRaw: String

    // Bookkeeping / lifecycle
    @Field(key: "is_active")
    public var isActive: Bool
    
    @Field(key: "is_subscribed")
    public var isSubscribed: Bool

    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    @Field(key: "last_seen_at")
    public var lastSeenAt: Date

    public init() {}

    public init(
        installationId: UUID,
        apnsDeviceToken: String,
        apnsEnvironment: APNsEnvironment,
        platform: Platform,
        osVersion: String,
        appVersion: String,
        buildNumber: String,
        locationAuth: LocationAuth,
        isActive: Bool = true,
        lastSeenAt: Date = .now,
        isSubscribed: Bool = true
    ) {
        self.id = installationId
        self.apnsDeviceToken = apnsDeviceToken
        self.apnsEnvironmentRaw = apnsEnvironment.rawValue
        self.platformRaw = platform.rawValue
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.locationAuthRaw = locationAuth.rawValue
        self.isActive = isActive
        self.lastSeenAt = lastSeenAt
        self.isSubscribed = isSubscribed
    }

    // MARK: Typed accessors (optional convenience)
    public var apnsEnvironment: APNsEnvironment {
        get { APNsEnvironment(rawValue: apnsEnvironmentRaw) ?? .prod }
        set { apnsEnvironmentRaw = newValue.rawValue }
    }

    public var platform: Platform {
        get { Platform(rawValue: platformRaw) ?? .iOS }
        set { platformRaw = newValue.rawValue }
    }

    public var locationAuth: LocationAuth {
        get { LocationAuth(rawValue: locationAuthRaw) ?? .unknown }
        set { locationAuthRaw = newValue.rawValue }
    }
}

//public extension DeviceLocationModel {
//    convenience init(from snapshot: LocationSnapshotPushPayload) throws {
//        
//        let uuid = snapshot.installationId
//        self.init(
//            id: uuid
//        )
//    }
//}

// MARK: - Enums (keep as Strings in DB)
public enum APNsEnvironment: String, Codable, Sendable {
    case prod
    case sandbox
}

public enum Platform: String, Codable, Sendable {
    case iOS
    case watchOS
}

public enum LocationAuth: String, Codable, Sendable {
    case always
    case whenInUse
    case denied
    case restricted
    case notDetermined
    case unknown
}
