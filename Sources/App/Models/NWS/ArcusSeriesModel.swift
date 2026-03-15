//
//  ArcusSeriesModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/26/26.
//

import Fluent
import Foundation
import Crypto

public enum ArcusEventModelError: Error, Sendable {
    case invalidEnum(field: String, value: String)
    case invalidGeometryJSON
}

//area desc, status, category, event, senderName, headline, description, instructions, response

public final class ArcusSeriesModel: Model, @unchecked Sendable {
    public static let schema = "arcus_series"
    
    // MARK: Identity
    @ID(key: .id) // The series id
    public var id: UUID?
    
    @Field(key: "source")
    public var source: String
    
    @Field(key: "event")
    public var event: String // event property in the message
    
    @Field(key: "source_url")
    public var sourceURL: String
    
    @Field(key: "current_revision_urn")
    public var currentRevisionUrn: String
    
    @Field(key: "current_revision_sent")
    public var currentRevisionSent: Date?
    
    @Field(key: "message_type")
    public var messageType: String
    
    @Field(key: "content_fingerprint")
    public var contentFingerprint: String
    
    
    // MARK: Lifecycle
    @Field(key: "state")
    public var state: String
    
    // When this object was created.
    @Timestamp(key: "created", on: .create)
    var created: Date?
    
    // When this object was last updated.
    @Timestamp(key: "updated", on: .update)
    var updated: Date?
    
    @Field(key: "last_seen_active")
    public var lastSeenActive: Date
    
    
    // MARK: Timing
    @OptionalField(key: "sent")
    public var sent: Date? // time of the origination of message itself
    
    @OptionalField(key: "effective")
    public var effective: Date? // goes into effect
    
    @OptionalField(key: "onset")
    public var onset: Date? // beginning of the event in message
    
    @OptionalField(key: "expires")
    public var expires: Date? // alert message expiration
    
    @OptionalField(key: "ends")
    public var ends: Date?
    
    
    // MARK: Severity inputs (normalized)
    // status is not needed, as we are only pulling Actual per the filter
    //    @Field(key: "status")
    //    public var status: String
    
    @Field(key: "severity")
    public var severity: String
    
    @Field(key: "urgency")
    public var urgency: String
    
    @Field(key: "certainty")
    public var certainty: String
    
    
    // MARK: Targeting
    @available(*, deprecated, message: "Move to ArcusGeolocationModel")
    @OptionalField(key: "geometry")
    public var geometry: GeoShape?
    
    @Field(key: "ugc_codes")
    public var ugcCodes: [String]
    
    
    // MARK: Human-facing metadata
    @OptionalField(key: "title")
    public var title: String?
    
    @OptionalField(key: "area_desc")
    public var areaDesc: String?
    
    @OptionalField(key:"category")
    public var category: String?
        
    @OptionalField(key:"sender_name")
    public var senderName: String?
    
    @OptionalField(key:"headline")
    public var headline: String?
    
    @OptionalField(key:"description")
    public var description: String?
    
    @OptionalField(key:"instructions")
    public var instructions: String?
    
    @OptionalField(key:"response")
    public var response: String?
    
    @OptionalField(key:"status")
    public var status: String?
    
    @OptionalChild(for: \.$series)
    var geolocation: ArcusGeolocationModel?
    
    @Children(for: \.$series)
    var revisions: [ArcusEventRevisionModel]
    
    
    // MARK: Inits
    public init() {}
    
    public init(
        id: UUID? = nil,
        source: String,
        event: String,
        sourceURL: String,
        currentRevisionUrn: String,
        currentRevisionSent: Date? = nil,
        messageType: String,
        contentFingerprint: String,
        state: String,
        created: Date? = nil,
        updated: Date? = nil,
        sent: Date? = nil,
        effective: Date? = nil,
        onset: Date? = nil,
        expires: Date? = nil,
        ends: Date? = nil,
        lastSeenActive: Date,
        severity: String,
        urgency: String,
        certainty: String,
        ugcCodes: [String],
        title: String? = nil,
        areaDesc: String? = nil,
        geometry: GeoShape? = nil,
        category: String? = nil,
        senderName: String? = nil,
        headline: String? = nil,
        description: String? = nil,
        instructions: String? = nil,
        response: String? = nil,
        status: String? = nil
    ) {
        self.id = id
        self.source = source
        self.event = event
        self.sourceURL = sourceURL
        self.currentRevisionUrn = currentRevisionUrn
        self.currentRevisionSent = currentRevisionSent
        self.messageType = messageType
        self.contentFingerprint = contentFingerprint
        self.state = state
        self.created = created
        self.updated = updated
        self.sent = sent
        self.effective = effective
        self.onset = onset
        self.expires = expires
        self.ends = ends
        self.lastSeenActive = lastSeenActive
        self.severity = severity
        self.urgency = urgency
        self.certainty = certainty
        self.ugcCodes = ugcCodes
        self.title = title
        self.areaDesc = areaDesc
        self.geometry = geometry
        self.category = category
        self.senderName = senderName
        self.headline = headline
        self.description = description
        self.instructions = instructions
        self.response = response
        self.status = status
    }
}


// MARK: Extensions
public extension ArcusSeriesModel {
    convenience init(from event: ArcusEvent, asOf: Date = .now) throws {
        self.init(
            source: event.source.rawValue,
            event: event.kind,
            sourceURL: event.sourceURL,
            currentRevisionUrn: event.id,
            currentRevisionSent: event.sent,
            messageType: event.messageType.rawValue,
            contentFingerprint: try event.computeContentFingerprint(),
            state: event.state.rawValue,
            created: nil,
            updated: nil,
            sent: event.sent,
            effective: event.effective,
            onset: event.onset,
            expires: event.expires,
            ends: event.ends,
            lastSeenActive: asOf,
            severity: event.severity.rawValue,
            urgency: event.urgency.rawValue,
            certainty: event.certainty.rawValue,
            ugcCodes: event.ugcCodes,
            title: event.title,
            areaDesc: event.areaDesc,
            geometry: event.geometry,
            category: event.category,
            senderName: event.senderName,
            headline: event.headline,
            description: event.description,
            instructions: event.instructions,
            response: event.response,
            status: event.status
        )
    }
    
    func asDomain() throws -> ArcusEvent {
        guard let source = EventSource(rawValue: source) else {
            throw ArcusEventModelError.invalidEnum(field: "source", value: source)
        }
        
        guard let severity = EventSeverity(rawValue: severity) else {
            throw ArcusEventModelError.invalidEnum(field: "severity", value: severity)
        }
        
        guard let urgency = EventUrgency(rawValue: urgency) else {
            throw ArcusEventModelError.invalidEnum(field: "urgency", value: urgency)
        }
        
        guard let certainty = EventCertainty(rawValue: certainty) else {
            throw ArcusEventModelError.invalidEnum(field: "certainty", value: certainty)
        }
        
        guard let messageType = NWSAlertMessageType(rawValue: messageType) else {
            throw ArcusEventModelError.invalidEnum(field: "messageType", value: messageType)
        }
        
        guard let state = EventState(rawValue: state) else {
            throw ArcusEventModelError.invalidEnum(field: "state", value: state)
        }
        
        return .init(
            urn: currentRevisionUrn,
            source: source,
            kind: event,
            sourceURL: sourceURL,
            vtec: nil, // Just nil, since we don't persist
            messageType: messageType,
            state: state,
            references: [], // TODO: Figure this out too
            sent: sent,
            effective: effective,
            onset: onset,
            expires: expires,
            ends: ends,
            lastSeenActive: lastSeenActive,
            severity: severity,
            urgency: urgency,
            certainty: certainty,
            geometry: geometry,
            ugcCodes: ugcCodes,
            title: title,
            areaDesc: areaDesc,
            rawRef: nil,
            category: category,
            event: event,
            senderName: senderName,
            headline: headline,
            description: description,
            instructions: instructions,
            response: response,
            status: status
        )
    }
}
