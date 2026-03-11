//
//  ArcusNotificationOutboxModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/3/26.
//

import Fluent
import Foundation

public final class ArcusNotificationOutboxModel: Model, @unchecked Sendable {
    public static let schema = "notification_outbox"
    
    @ID(key: .id)
    public var id: UUID?
 
    @Parent(key: "series_id")
    public var series: ArcusSeriesModel
    
    @Field(key: "revision_urn")
    public var revisionUrn: String
    
    @Field(key: "mode")
    public var mode: String //ugc|h3
    
    @Field(key: "reason")
    public var reason: String //new|update|cancelled|endedAllClear
    
    @Field(key: "state")
    public var state: String //pending|ready|processing|done|dead
    
    @Field(key: "attempts")
    public var attempts: Int
    
    @OptionalField(key: "last_error")
    public var lastError: String?

    @Field(key: "available_at")
    public var availableAt: Date
    
    // When this object was created.
    @Timestamp(key: "created", on: .create)
    var created: Date?
    
    // When this object was last updated.
    @Timestamp(key: "updated", on: .update)
    var updated: Date?
    
    // MARK: Inits
    public init() {}
    
    public init(
        id: UUID? = nil,
        series: UUID,
        revisionUrn: String,
        mode: String,
        reason: String,
        state: String,
        attempts: Int,
        lastError: String? = nil,
        availableAt: Date
    ) {
        self.id = id
        self.$series.id = series
        self.revisionUrn = revisionUrn
        self.mode = mode
        self.reason = reason
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.availableAt = availableAt
    }
}


//•    id UUID PK
//•    series_id UUID
//•    revision_urn TEXT
//•    mode TEXT (h3|ugc)
//•    state TEXT (pending|ready|processing|done|dead)
//•    created_at, updated_at

//•    available_at (for backoff / delayed readiness)
//•    attempts INT
//•    last_error TEXT NULL

//Add a unique constraint so you don’t enqueue duplicates:
//    •    UNIQUE(series_id, revision_urn, mode)
