//
//  NotificationDebugModel.swift
//  ArcusSignal
//
//  Created by Codex on 4/9/26.
//

import Fluent
import Foundation

public enum NotificationDebugRecordKind: String, Codable, Sendable {
    case previewNoCandidates = "preview_no_candidates"
    case candidate
}

public final class NotificationDebugModel: Model, @unchecked Sendable {
    public static let schema = "notification_debug"

    @ID(key: .id)
    public var id: UUID?

    @OptionalParent(key: "series_id")
    public var series: ArcusSeriesModel?

    @OptionalField(key: "installation_id")
    public var installationID: UUID?

    @OptionalField(key: "notification_ledger_id")
    public var notificationLedgerID: UUID?

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
    public var mode: String

    @Field(key: "reason")
    public var reason: String

    @Field(key: "record_kind")
    public var recordKind: String

    @Field(key: "title")
    public var title: String

    @Field(key: "subtitle")
    public var subtitle: String

    @Field(key: "body")
    public var body: String

    @Timestamp(key: "created", on: .create)
    public var created: Date?

    public init() {}

    public init(
        id: UUID? = nil,
        seriesID: UUID?,
        installationID: UUID? = nil,
        notificationLedgerID: UUID? = nil,
        revisionUrn: String,
        mode: String,
        reason: String,
        recordKind: NotificationDebugRecordKind,
        title: String,
        subtitle: String,
        body: String,
        subject: NotificationSubject? = nil
    ) {
        self.id = id
        self.$series.id = seriesID
        self.installationID = installationID
        self.notificationLedgerID = notificationLedgerID
        self.subjectKindRaw = subject?.kind.rawValue
        self.subjectID = subject?.productID
        self.subjectRevisionID = subject?.revisionID
        self.revisionUrn = revisionUrn
        self.mode = mode
        self.reason = reason
        self.recordKind = recordKind.rawValue
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}
