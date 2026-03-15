//
//  DevicePresenceModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/4/26.
//

import Foundation
import Fluent
import Vapor

public enum CellScheme: String, Codable, Sendable {
    case h3
    case ugcOnly = "ugc-only"
}

public enum LocationSource: String, Codable, Sendable {
    case foreground
    case backgroundRefresh
    case significantChange
    case manual
    case unknown
}

public final class DevicePresenceModel: Model, @unchecked Sendable {
    public static let schema = "device_presence"

    // PK = installation_id (also FK to device_installations)
    @ID(custom: "installation_id", generatedBy: .user)
    public var id: UUID?

    // Timestamps / quality
    @Field(key: "captured_at")
    public var capturedAt: Date

    @Field(key: "received_at")
    public var receivedAt: Date

    @Field(key: "location_age_seconds")
    public var locationAgeSeconds: Double

    @Field(key: "horizontal_accuracy_meters")
    public var horizontalAccuracyMeters: Double

    // Targeting primitives
    @Field(key: "cell_scheme")
    public var cellSchemeRaw: String

    @Field(key: "h3_cell")
    public var h3Cell: Int64?

    @Field(key: "h3_resolution")
    public var h3Resolution: Int?

    // UGC targeting (coarse)
    @Field(key: "county")
    public var county: String?

    @Field(key: "zone")
    public var zone: String?

    @Field(key: "fire_zone")
    public var fireZone: String?

    @OptionalField(key: "county_label")
    public var countyLabel: String?
    
    @OptionalField(key: "fire_zone_label")
    public var fireZoneLabel: String?
    
    // Capture context
    @Field(key: "source")
    public var sourceRaw: String

    // Bookkeeping
    @Timestamp(key: "created_at", on: .create)
    public var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    public var updatedAt: Date?

    public init() {}

    public init(
        installationId: UUID,
        capturedAt: Date,
        receivedAt: Date = .now,
        locationAgeSeconds: Double,
        horizontalAccuracyMeters: Double,
        cellScheme: CellScheme,
        h3Cell: Int64?,
        h3Resolution: Int?,
        county: String?,
        zone: String?,
        fireZone: String?,
        source: LocationSource,
        countyLabel: String?,
        fireZoneLabel: String?
    ) {
        self.id = installationId
        self.capturedAt = capturedAt
        self.receivedAt = receivedAt
        self.locationAgeSeconds = locationAgeSeconds
        self.horizontalAccuracyMeters = horizontalAccuracyMeters
        self.cellSchemeRaw = cellScheme.rawValue
        self.h3Cell = h3Cell
        self.h3Resolution = h3Resolution
        self.county = county
        self.zone = zone
        self.fireZone = fireZone
        self.sourceRaw = source.rawValue
        self.countyLabel = countyLabel
        self.fireZoneLabel = fireZoneLabel
    }

    // MARK: Typed accessors (optional convenience)
    public var cellScheme: CellScheme {
        get { CellScheme(rawValue: cellSchemeRaw) ?? .ugcOnly }
        set { cellSchemeRaw = newValue.rawValue }
    }

    public var source: LocationSource {
        get { LocationSource(rawValue: sourceRaw) ?? .unknown }
        set { sourceRaw = newValue.rawValue }
    }
}
