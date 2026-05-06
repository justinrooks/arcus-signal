//
//  NotificationLedgerModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/10/26.
//

import Foundation
import Fluent
import Vapor

public final class NotificationLedgerModel: Model, @unchecked Sendable, Content {
    public static let schema = "notification_ledger"
    
    @ID(key: .id)
    public var id: UUID?
    
    @Parent(key: "installation_id")
    public var deviceInstallation: DeviceInstallationModel
    
    @Parent(key: "series_id")
    public var series: ArcusSeriesModel
    
    @Field(key: "revision_urn")
    public var revisionUrn: String
    
    @Field(key: "mode")
    public var mode: String //ugc|h3
    
    @Field(key: "reason")
    public var reason: String

    @OptionalField(key: "freshness_state")
    public var freshnessStateRaw: String?
    
    @OptionalField(key: "status")
    public var status: String?
    
    @OptionalField(key: "apns_error_code")
    public var apnsErrorCode: String?

    @OptionalField(key: "completed_at")
    public var completedAt: Date?
    
    // Bookkeeping
    @Timestamp(key: "created", on: .create)
    public var created: Date?
    
    public init() {}
    
    public init(
        id: UUID? = nil,
        installationId: UUID,
        series: UUID,
        revisionUrn: String,
        mode: String,
        reason: String,
        freshnessState: LocationFreshnessState,
        status: String?,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.$deviceInstallation.id = installationId
        self.$series.id = series
        self.revisionUrn = revisionUrn
        self.mode = mode
        self.reason = reason
        self.freshnessStateRaw = freshnessState.rawValue
        self.status = status
        self.completedAt = completedAt
    }

    public var freshnessState: LocationFreshnessState? {
        get {
            guard let freshnessStateRaw else { return nil }
            return LocationFreshnessState(rawValue: freshnessStateRaw)
        }
        set { freshnessStateRaw = newValue?.rawValue }
    }
}
