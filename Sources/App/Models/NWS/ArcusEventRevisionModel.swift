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
    
    @Parent(key: "series_id")
    public var series: ArcusSeriesModel
    
    @Field(key: "revision_urn")
    public var revisionUrn: String
    
    @Field(key: "message_type")
    public var messageType: String
    
    @Field(key: "sent")
    public var sent: Date
    
    @Field(key: "received")
    public var received: Date
    
    @Field(key: "referenced_urns")
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
        self.$series.id = seriesId
        self.revisionUrn = revisionUrn
        self.messageType = messageType
        self.sent = sent
        self.received = received
        self.referencedUrns = referencedUrns
    }
}

// MARK: Extensions
public extension ArcusEventRevisionModel {
    convenience init(from event: ArcusEvent, seriesId id: UUID, asOf: Date = .now) throws {
        self.init(
            seriesId: id,
            revisionUrn: event.id,
            messageType: event.messageType.rawValue,
            sent: event.sent ?? asOf,
            received: asOf,
            referencedUrns: event.references
        )
    }
    
    static func resolveSeriesIDs(
        referencedURNs: [String],
        on db: any Database
    ) async throws -> Set<UUID> {
        guard !referencedURNs.isEmpty else {return []}
        
        //Fetch
        let rows = try await ArcusEventRevisionModel.query(on: db)
            .filter(\.$revisionUrn ~~ referencedURNs)
            .all()
        
        return Set(rows.compactMap{ $0.$series.id })
    }
}
