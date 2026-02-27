//
//  ArcusEventRevisionModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/27/26.
//

import Fluent
import Foundation

public final class ArcusEventRevisionModel: Model, @unchecked Sendable {
    public static let schema = "alert_revisions"
    
    // MARK: Identity
    @ID(key: .id) // The series id
    public var id: UUID?
    
    @Field(key: "series_id")
    public var seriesId: UUID
    
    @Field(key: "revision_urn")
    public var revisionUrn: String
    
    @Field(key: "message_type")
    public var messageType: String
    
    @Field(key: "sent")
    public var sent: Date
    
    @Field(key: "received")
    public var received: Date
    
    @Field(key: "reference_urns")
    public var referencedUrns: [String]
    
    
    // MARK: Inits
    public init() {}
    
    public init(
        id: UUID? = nil,
        seriesId: UUID,
        revisionUrn: String,
        messageType: String,
        sent: Date,
        received: Date,
        referencedUrns: [String]
    ) {
        self.id = id
        self.seriesId = seriesId
        self.revisionUrn = revisionUrn
        self.messageType = messageType
        self.sent = sent
        self.received = received
        self.referencedUrns = referencedUrns
    }
    
    // Example of a parent relation.
//        @Parent(key: "star_id")
//        var star: Star
}
