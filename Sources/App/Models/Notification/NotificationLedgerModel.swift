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
    
    @OptionalParent(key: "series_id")
    public var series: ArcusSeriesModel?
    
    @OptionalField(key: "subject_kind")
    public var subjectKindRaw: String?

    @OptionalField(key: "subject_id")
    public var subjectID: String?

    @OptionalField(key: "subject_revision_id")
    public var subjectRevisionID: String?

    public var subject: NotificationSubject? {
        NotificationSubject.resolve(kind: subjectKindRaw, productID: subjectID,
                                    revisionID: subjectRevisionID, seriesID: self.$series.id, revisionUrn: revisionUrn)
    }

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
        series: UUID?,
        revisionUrn: String,
        mode: String,
        reason: String,
        freshnessState: LocationFreshnessState,
        status: String?,
        completedAt: Date? = nil,
        subject: NotificationSubject? = nil
    ) {
        self.id = id
        self.$deviceInstallation.id = installationId
        self.$series.id = series
        self.subjectKindRaw = subject?.kind.rawValue
        self.subjectID = subject?.productID
        self.subjectRevisionID = subject?.revisionID
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
