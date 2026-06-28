import Foundation
import Vapor

public struct OperatorDashboardStoredSnapshot: Codable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var generatedAt: Date

    public var fastRefreshedAt: Date?
    public var standardRefreshedAt: Date?
    public var slowRefreshedAt: Date?

    public var ingestFreshness: StoredIngestFreshnessMetric
    public var pipelineBacklog: StoredPipelineBacklogMetric
    public var stuckClaimedRows: StoredStuckClaimedRowsMetric
    public var staleActiveSeries: StoredStaleActiveSeriesMetric
    public var endToEndLatency: StoredEndToEndLatencyMetric
    public var apnsDelivery: StoredAPNsDeliveryMetric
    public var sendNoOps: StoredSendNoOpsMetric
    public var zeroCandidateRate: StoredZeroCandidateRateMetric
    public var targetableCoverage: StoredTargetableCoverageMetric
    public var h3Derivation: StoredH3DerivationMetric
    public var modelArtifacts: StoredPressureArtifactDashboardMetric
    public var recentNotificationDebugEntries: [StoredRecentNotificationDebugEntry]
    public var touchedSeries: [StoredTouchedSeriesEntry]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        fastRefreshedAt: Date? = nil,
        standardRefreshedAt: Date? = nil,
        slowRefreshedAt: Date? = nil,
        ingestFreshness: StoredIngestFreshnessMetric = .init(),
        pipelineBacklog: StoredPipelineBacklogMetric = .init(),
        stuckClaimedRows: StoredStuckClaimedRowsMetric = .init(),
        staleActiveSeries: StoredStaleActiveSeriesMetric = .init(),
        endToEndLatency: StoredEndToEndLatencyMetric = .init(),
        apnsDelivery: StoredAPNsDeliveryMetric = .init(),
        sendNoOps: StoredSendNoOpsMetric = .init(),
        zeroCandidateRate: StoredZeroCandidateRateMetric = .init(),
        targetableCoverage: StoredTargetableCoverageMetric = .init(),
        h3Derivation: StoredH3DerivationMetric = .init(),
        modelArtifacts: StoredPressureArtifactDashboardMetric = .init(),
        recentNotificationDebugEntries: [StoredRecentNotificationDebugEntry] = [],
        touchedSeries: [StoredTouchedSeriesEntry] = []
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.fastRefreshedAt = fastRefreshedAt
        self.standardRefreshedAt = standardRefreshedAt
        self.slowRefreshedAt = slowRefreshedAt
        self.ingestFreshness = ingestFreshness
        self.pipelineBacklog = pipelineBacklog
        self.stuckClaimedRows = stuckClaimedRows
        self.staleActiveSeries = staleActiveSeries
        self.endToEndLatency = endToEndLatency
        self.apnsDelivery = apnsDelivery
        self.sendNoOps = sendNoOps
        self.zeroCandidateRate = zeroCandidateRate
        self.targetableCoverage = targetableCoverage
        self.h3Derivation = h3Derivation
        self.modelArtifacts = modelArtifacts
        self.recentNotificationDebugEntries = recentNotificationDebugEntries
        self.touchedSeries = touchedSeries
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case fastRefreshedAt
        case standardRefreshedAt
        case slowRefreshedAt
        case ingestFreshness
        case pipelineBacklog
        case stuckClaimedRows
        case staleActiveSeries
        case endToEndLatency
        case apnsDelivery
        case sendNoOps
        case zeroCandidateRate
        case targetableCoverage
        case h3Derivation
        case modelArtifacts
        case recentNotificationDebugEntries
        case touchedSeries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.fastRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .fastRefreshedAt)
        self.standardRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .standardRefreshedAt)
        self.slowRefreshedAt = try container.decodeIfPresent(Date.self, forKey: .slowRefreshedAt)
        self.ingestFreshness = try container.decode(StoredIngestFreshnessMetric.self, forKey: .ingestFreshness)
        self.pipelineBacklog = try container.decode(StoredPipelineBacklogMetric.self, forKey: .pipelineBacklog)
        self.stuckClaimedRows = try container.decode(StoredStuckClaimedRowsMetric.self, forKey: .stuckClaimedRows)
        self.staleActiveSeries = try container.decode(StoredStaleActiveSeriesMetric.self, forKey: .staleActiveSeries)
        self.endToEndLatency = try container.decode(StoredEndToEndLatencyMetric.self, forKey: .endToEndLatency)
        self.apnsDelivery = try container.decode(StoredAPNsDeliveryMetric.self, forKey: .apnsDelivery)
        self.sendNoOps = try container.decode(StoredSendNoOpsMetric.self, forKey: .sendNoOps)
        self.zeroCandidateRate = try container.decode(StoredZeroCandidateRateMetric.self, forKey: .zeroCandidateRate)
        self.targetableCoverage = try container.decode(StoredTargetableCoverageMetric.self, forKey: .targetableCoverage)
        self.h3Derivation = try container.decode(StoredH3DerivationMetric.self, forKey: .h3Derivation)
        self.modelArtifacts = try container.decodeIfPresent(StoredPressureArtifactDashboardMetric.self, forKey: .modelArtifacts) ?? .init()
        self.recentNotificationDebugEntries = try container.decode([StoredRecentNotificationDebugEntry].self, forKey: .recentNotificationDebugEntries)
        self.touchedSeries = try container.decode([StoredTouchedSeriesEntry].self, forKey: .touchedSeries)
    }
}

public extension OperatorDashboardStoredSnapshot {
    static func empty(now: Date = .now) -> Self {
        .init(generatedAt: now)
    }
}

public struct StoredIngestFreshnessMetric: Codable, Sendable {
    public var recentAttemptLimit: Int
    public var lastSuccessfulCompletedAt: Date?
    public var lastAttemptCompletedAt: Date?
    public var recentSuccessCount: Int
    public var recentFailureCount: Int
    public var lastFailureCompletedAt: Date?
    public var lastFailureMessage: String?

    public init(
        recentAttemptLimit: Int = OperatorDashboardConfig.ingestRecentAttemptLimit,
        lastSuccessfulCompletedAt: Date? = nil,
        lastAttemptCompletedAt: Date? = nil,
        recentSuccessCount: Int = 0,
        recentFailureCount: Int = 0,
        lastFailureCompletedAt: Date? = nil,
        lastFailureMessage: String? = nil
    ) {
        self.recentAttemptLimit = recentAttemptLimit
        self.lastSuccessfulCompletedAt = lastSuccessfulCompletedAt
        self.lastAttemptCompletedAt = lastAttemptCompletedAt
        self.recentSuccessCount = recentSuccessCount
        self.recentFailureCount = recentFailureCount
        self.lastFailureCompletedAt = lastFailureCompletedAt
        self.lastFailureMessage = lastFailureMessage
    }
}

public struct StoredPipelineBacklogMetric: Codable, Sendable {
    public var pendingTargetDispatchCount: Int
    public var oldestPendingTargetDispatchCreatedAt: Date?
    public var pendingNotificationDispatchCount: Int
    public var oldestPendingNotificationDispatchCreatedAt: Date?

    public init(
        pendingTargetDispatchCount: Int = 0,
        oldestPendingTargetDispatchCreatedAt: Date? = nil,
        pendingNotificationDispatchCount: Int = 0,
        oldestPendingNotificationDispatchCreatedAt: Date? = nil
    ) {
        self.pendingTargetDispatchCount = pendingTargetDispatchCount
        self.oldestPendingTargetDispatchCreatedAt = oldestPendingTargetDispatchCreatedAt
        self.pendingNotificationDispatchCount = pendingNotificationDispatchCount
        self.oldestPendingNotificationDispatchCreatedAt = oldestPendingNotificationDispatchCreatedAt
    }
}

public struct StoredStuckClaimedRowsMetric: Codable, Sendable {
    public var thresholdSeconds: Int
    public var count: Int
    public var oldestClaimedCreatedAt: Date?

    public init(
        thresholdSeconds: Int = OperatorDashboardConfig.claimedStuckThresholdSeconds,
        count: Int = 0,
        oldestClaimedCreatedAt: Date? = nil
    ) {
        self.thresholdSeconds = thresholdSeconds
        self.count = count
        self.oldestClaimedCreatedAt = oldestClaimedCreatedAt
    }
}

public struct StoredStaleActiveSeriesMetric: Codable, Sendable {
    public var graceSeconds: Int
    public var count: Int

    public init(
        graceSeconds: Int = OperatorDashboardConfig.staleActiveSeriesGraceSeconds,
        count: Int = 0
    ) {
        self.graceSeconds = graceSeconds
        self.count = count
    }
}

public struct StoredEndToEndLatencyMetric: Codable, Sendable {
    public var windowHours: Int
    public var successfulRevisionCount: Int
    public var p95Seconds: Double?

    public init(
        windowHours: Int = OperatorDashboardConfig.rollingWindowHours,
        successfulRevisionCount: Int = 0,
        p95Seconds: Double? = nil
    ) {
        self.windowHours = windowHours
        self.successfulRevisionCount = successfulRevisionCount
        self.p95Seconds = p95Seconds
    }
}

public struct StoredReasonCount: Codable, Sendable {
    public var reason: String
    public var count: Int

    public init(reason: String, count: Int) {
        self.reason = reason
        self.count = count
    }
}

public struct StoredAPNsDeliveryMetric: Codable, Sendable {
    public var windowHours: Int
    public var sentCount: Int
    public var failedCount: Int
    public var topFailureReasons: [StoredReasonCount]

    public init(
        windowHours: Int = OperatorDashboardConfig.rollingWindowHours,
        sentCount: Int = 0,
        failedCount: Int = 0,
        topFailureReasons: [StoredReasonCount] = []
    ) {
        self.windowHours = windowHours
        self.sentCount = sentCount
        self.failedCount = failedCount
        self.topFailureReasons = topFailureReasons
    }
}

public struct StoredSendNoOpsMetric: Codable, Sendable {
    public var windowHours: Int
    public var totalAttemptCount: Int
    public var noOpAttemptCount: Int
    public var reasons: [StoredReasonCount]

    public init(
        windowHours: Int = OperatorDashboardConfig.rollingWindowHours,
        totalAttemptCount: Int = 0,
        noOpAttemptCount: Int = 0,
        reasons: [StoredReasonCount] = []
    ) {
        self.windowHours = windowHours
        self.totalAttemptCount = totalAttemptCount
        self.noOpAttemptCount = noOpAttemptCount
        self.reasons = reasons
    }
}

public struct StoredZeroCandidateRateMetric: Codable, Sendable {
    public var windowHours: Int
    public var candidateResolutionAttemptCount: Int
    public var zeroCandidateAttemptCount: Int

    public init(
        windowHours: Int = OperatorDashboardConfig.rollingWindowHours,
        candidateResolutionAttemptCount: Int = 0,
        zeroCandidateAttemptCount: Int = 0
    ) {
        self.windowHours = windowHours
        self.candidateResolutionAttemptCount = candidateResolutionAttemptCount
        self.zeroCandidateAttemptCount = zeroCandidateAttemptCount
    }
}

public struct StoredTargetableCoverageBreakdown: Codable, Sendable {
    public var missingDeviceTokenCount: Int
    public var staleInstallationHeartbeatCount: Int
    public var stalePresenceCount: Int
    public var missingTargetingDataCount: Int

    public init(
        missingDeviceTokenCount: Int = 0,
        staleInstallationHeartbeatCount: Int = 0,
        stalePresenceCount: Int = 0,
        missingTargetingDataCount: Int = 0
    ) {
        self.missingDeviceTokenCount = missingDeviceTokenCount
        self.staleInstallationHeartbeatCount = staleInstallationHeartbeatCount
        self.stalePresenceCount = stalePresenceCount
        self.missingTargetingDataCount = missingTargetingDataCount
    }
}

public struct StoredTargetableCoverageMetric: Codable, Sendable {
    public var installationFreshnessSeconds: Int
    public var presenceFreshnessSeconds: Int
    public var activeSubscribedInstallationCount: Int
    public var targetableInstallationCount: Int
    public var lossBreakdown: StoredTargetableCoverageBreakdown

    public init(
        installationFreshnessSeconds: Int = OperatorDashboardConfig.installationFreshnessThresholdSeconds,
        presenceFreshnessSeconds: Int = OperatorDashboardConfig.presenceFreshnessThresholdSeconds,
        activeSubscribedInstallationCount: Int = 0,
        targetableInstallationCount: Int = 0,
        lossBreakdown: StoredTargetableCoverageBreakdown = .init()
    ) {
        self.installationFreshnessSeconds = installationFreshnessSeconds
        self.presenceFreshnessSeconds = presenceFreshnessSeconds
        self.activeSubscribedInstallationCount = activeSubscribedInstallationCount
        self.targetableInstallationCount = targetableInstallationCount
        self.lossBreakdown = lossBreakdown
    }
}

public struct StoredH3DerivationMetric: Codable, Sendable {
    public var windowHours: Int
    public var geometryBearingRevisionCount: Int
    public var successfulConversionCount: Int
    public var p95ConversionSeconds: Double?

    public init(
        windowHours: Int = OperatorDashboardConfig.rollingWindowHours,
        geometryBearingRevisionCount: Int = 0,
        successfulConversionCount: Int = 0,
        p95ConversionSeconds: Double? = nil
    ) {
        self.windowHours = windowHours
        self.geometryBearingRevisionCount = geometryBearingRevisionCount
        self.successfulConversionCount = successfulConversionCount
        self.p95ConversionSeconds = p95ConversionSeconds
    }
}

public struct StoredPressureArtifactDashboardMetric: Codable, Sendable {
    public var pressureArtifactReadiness: StoredPressureArtifactDashboardReadinessMetric
    public var pressureArtifactCatalog: StoredPressureArtifactDashboardCatalogMetric
    public var recentPressureArtifacts: StoredPressureArtifactDashboardRecentEntriesMetric

    public init(
        pressureArtifactReadiness: StoredPressureArtifactDashboardReadinessMetric = .init(),
        pressureArtifactCatalog: StoredPressureArtifactDashboardCatalogMetric = .init(),
        recentPressureArtifacts: StoredPressureArtifactDashboardRecentEntriesMetric = .init()
    ) {
        self.pressureArtifactReadiness = pressureArtifactReadiness
        self.pressureArtifactCatalog = pressureArtifactCatalog
        self.recentPressureArtifacts = recentPressureArtifacts
    }
}

public struct StoredPressureArtifactDashboardReadinessMetric: Codable, Sendable {
    public var refreshedAt: Date?
    public var status: String?
    public var runTime: Date?
    public var forecastHour: Int?
    public var validTime: Date?
    public var fieldSetVersion: String?
    public var byteSize: Int64?
    public var source: String?
    public var updatedAt: Date?
    public var lastCheckedAt: Date?
    public var errorSummary: String?

    public init(
        refreshedAt: Date? = nil,
        status: String? = nil,
        runTime: Date? = nil,
        forecastHour: Int? = nil,
        validTime: Date? = nil,
        fieldSetVersion: String? = nil,
        byteSize: Int64? = nil,
        source: String? = nil,
        updatedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        errorSummary: String? = nil
    ) {
        self.refreshedAt = refreshedAt
        self.status = status
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.fieldSetVersion = fieldSetVersion
        self.byteSize = byteSize
        self.source = source
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.errorSummary = errorSummary
    }
}

public struct StoredPressureArtifactDashboardCatalogMetric: Codable, Sendable {
    public var refreshedAt: Date?
    public var totalRowCount: Int
    public var pendingCount: Int
    public var warmingCount: Int
    public var readyCount: Int
    public var failedCount: Int
    public var expiredCount: Int
    public var mostRecentFailureAt: Date?
    public var mostRecentFailureSummary: String?

    public init(
        refreshedAt: Date? = nil,
        totalRowCount: Int = 0,
        pendingCount: Int = 0,
        warmingCount: Int = 0,
        readyCount: Int = 0,
        failedCount: Int = 0,
        expiredCount: Int = 0,
        mostRecentFailureAt: Date? = nil,
        mostRecentFailureSummary: String? = nil
    ) {
        self.refreshedAt = refreshedAt
        self.totalRowCount = totalRowCount
        self.pendingCount = pendingCount
        self.warmingCount = warmingCount
        self.readyCount = readyCount
        self.failedCount = failedCount
        self.expiredCount = expiredCount
        self.mostRecentFailureAt = mostRecentFailureAt
        self.mostRecentFailureSummary = mostRecentFailureSummary
    }
}

public struct StoredPressureArtifactDashboardRecentEntriesMetric: Codable, Sendable {
    public var refreshedAt: Date?
    public var entries: [StoredPressureArtifactDashboardEntry]

    public init(
        refreshedAt: Date? = nil,
        entries: [StoredPressureArtifactDashboardEntry] = []
    ) {
        self.refreshedAt = refreshedAt
        self.entries = entries
    }
}

public struct StoredPressureArtifactDashboardEntry: Codable, Sendable {
    public var runTime: Date
    public var forecastHour: Int
    public var validTime: Date
    public var product: String
    public var fieldSetVersion: String
    public var status: String
    public var byteSize: Int64?
    public var source: String
    public var createdAt: Date?
    public var updatedAt: Date?
    public var lastCheckedAt: Date?
    public var errorSummary: String?

    public init(
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        product: String,
        fieldSetVersion: String,
        status: String,
        byteSize: Int64? = nil,
        source: String,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        lastCheckedAt: Date? = nil,
        errorSummary: String? = nil
    ) {
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.product = product
        self.fieldSetVersion = fieldSetVersion
        self.status = status
        self.byteSize = byteSize
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastCheckedAt = lastCheckedAt
        self.errorSummary = errorSummary
    }
}

public struct StoredRecentNotificationDebugEntry: Codable, Sendable {
    public var createdAt: Date
    public var seriesID: UUID
    public var eventName: String
    public var recordKind: String
    public var mode: String
    public var reason: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var ledgerStatus: String?
    public var apnsErrorCode: String?

    public init(
        createdAt: Date,
        seriesID: UUID,
        eventName: String,
        recordKind: String,
        mode: String,
        reason: String,
        title: String,
        subtitle: String,
        body: String,
        ledgerStatus: String?,
        apnsErrorCode: String?
    ) {
        self.createdAt = createdAt
        self.seriesID = seriesID
        self.eventName = eventName
        self.recordKind = recordKind
        self.mode = mode
        self.reason = reason
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.ledgerStatus = ledgerStatus
        self.apnsErrorCode = apnsErrorCode
    }
}

public struct StoredTouchedSeriesEntry: Codable, Sendable {
    public var seriesID: UUID
    public var eventName: String
    public var state: String
    public var ugcCodes: [String]
    public var tornadoDetection: String?
    public var tornadoDamageThreat: String?
    public var currentRevisionUrn: String
    public var touchedAt: Date
    public var latestRevisionReceivedAt: Date?
    public var seriesUpdatedAt: Date?

    public init(
        seriesID: UUID,
        eventName: String,
        state: String,
        ugcCodes: [String] = [],
        tornadoDetection: String? = nil,
        tornadoDamageThreat: String? = nil,
        currentRevisionUrn: String,
        touchedAt: Date,
        latestRevisionReceivedAt: Date?,
        seriesUpdatedAt: Date?
    ) {
        self.seriesID = seriesID
        self.eventName = eventName
        self.state = state
        self.ugcCodes = ugcCodes
        self.tornadoDetection = tornadoDetection
        self.tornadoDamageThreat = tornadoDamageThreat
        self.currentRevisionUrn = currentRevisionUrn
        self.touchedAt = touchedAt
        self.latestRevisionReceivedAt = latestRevisionReceivedAt
        self.seriesUpdatedAt = seriesUpdatedAt
    }

    enum CodingKeys: String, CodingKey {
        case seriesID
        case eventName
        case state
        case ugcCodes
        case tornadoDetection
        case tornadoDamageThreat
        case currentRevisionUrn
        case touchedAt
        case latestRevisionReceivedAt
        case seriesUpdatedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.seriesID = try container.decode(UUID.self, forKey: .seriesID)
        self.eventName = try container.decode(String.self, forKey: .eventName)
        self.state = try container.decode(String.self, forKey: .state)
        self.ugcCodes = try container.decodeIfPresent([String].self, forKey: .ugcCodes) ?? []
        self.tornadoDetection = try container.decodeIfPresent(String.self, forKey: .tornadoDetection)
        self.tornadoDamageThreat = try container.decodeIfPresent(String.self, forKey: .tornadoDamageThreat)
        self.currentRevisionUrn = try container.decode(String.self, forKey: .currentRevisionUrn)
        self.touchedAt = try container.decode(Date.self, forKey: .touchedAt)
        self.latestRevisionReceivedAt = try container.decodeIfPresent(Date.self, forKey: .latestRevisionReceivedAt)
        self.seriesUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .seriesUpdatedAt)
    }
}

public struct OperatorDashboardSnapshotResponse: Content, Sendable {
    public var renderedAt: Date
    public var generatedAt: Date
    public var redLights: OperatorDashboardRedLightsSectionResponse
    public var deliveryKPIs: OperatorDashboardDeliveryKPIsSectionResponse
    public var audienceTargeting: OperatorDashboardAudienceTargetingSectionResponse
    public var modelArtifacts: OperatorDashboardModelArtifactsSectionResponse
    public var operatorContext: OperatorDashboardOperatorContextSectionResponse

    public init(snapshot: OperatorDashboardStoredSnapshot, renderedAt: Date = .now) {
        self.renderedAt = renderedAt
        self.generatedAt = snapshot.generatedAt
        self.redLights = .init(snapshot: snapshot, renderedAt: renderedAt)
        self.deliveryKPIs = .init(snapshot: snapshot, renderedAt: renderedAt)
        self.audienceTargeting = .init(snapshot: snapshot, renderedAt: renderedAt)
        self.modelArtifacts = .init(snapshot: snapshot, renderedAt: renderedAt)
        self.operatorContext = .init(snapshot: snapshot)
    }
}

public struct OperatorDashboardRedLightsSectionResponse: Content, Sendable {
    public var ingestFreshness: IngestFreshnessMetricResponse
    public var pipelineBacklogAge: PipelineBacklogMetricResponse
    public var stuckClaimedRows: StuckClaimedRowsMetricResponse
    public var staleActiveSeriesCount: StaleActiveSeriesMetricResponse

    init(snapshot: OperatorDashboardStoredSnapshot, renderedAt: Date) {
        self.ingestFreshness = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            renderedAt: renderedAt,
            metric: snapshot.ingestFreshness
        )
        self.pipelineBacklogAge = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            renderedAt: renderedAt,
            metric: snapshot.pipelineBacklog
        )
        self.stuckClaimedRows = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            renderedAt: renderedAt,
            metric: snapshot.stuckClaimedRows
        )
        self.staleActiveSeriesCount = .init(
            refreshedAt: snapshot.standardRefreshedAt,
            metric: snapshot.staleActiveSeries
        )
    }
}

public struct OperatorDashboardDeliveryKPIsSectionResponse: Content, Sendable {
    public var endToEndAlertLatency: EndToEndLatencyMetricResponse
    public var apnsDeliverySuccessRate: APNsDeliveryMetricResponse
    public var sendNoOpRateByReason: SendNoOpsMetricResponse
    public var zeroCandidateRevisionRate: ZeroCandidateRateMetricResponse

    init(snapshot: OperatorDashboardStoredSnapshot, renderedAt: Date) {
        self.endToEndAlertLatency = .init(
            refreshedAt: snapshot.slowRefreshedAt,
            metric: snapshot.endToEndLatency
        )
        self.apnsDeliverySuccessRate = .init(
            refreshedAt: snapshot.slowRefreshedAt,
            metric: snapshot.apnsDelivery
        )
        self.sendNoOpRateByReason = .init(
            refreshedAt: snapshot.standardRefreshedAt,
            metric: snapshot.sendNoOps
        )
        self.zeroCandidateRevisionRate = .init(
            refreshedAt: snapshot.standardRefreshedAt,
            metric: snapshot.zeroCandidateRate
        )
        _ = renderedAt
    }
}

public struct OperatorDashboardAudienceTargetingSectionResponse: Content, Sendable {
    public var freshTargetableInstallationCoverage: TargetableCoverageMetricResponse
    public var alertsWithGeographyAndH3Success: H3DerivationMetricResponse

    init(snapshot: OperatorDashboardStoredSnapshot, renderedAt: Date) {
        self.freshTargetableInstallationCoverage = .init(
            refreshedAt: snapshot.slowRefreshedAt,
            metric: snapshot.targetableCoverage
        )
        self.alertsWithGeographyAndH3Success = .init(
            refreshedAt: snapshot.standardRefreshedAt,
            metric: snapshot.h3Derivation
        )
        _ = renderedAt
    }
}

public struct OperatorDashboardModelArtifactsSectionResponse: Content, Sendable {
    public var pressureArtifactReadiness: PressureArtifactReadinessMetricResponse
    public var pressureArtifactCatalog: PressureArtifactCatalogMetricResponse
    public var recentPressureArtifacts: RecentPressureArtifactEntriesResponse

    init(snapshot: OperatorDashboardStoredSnapshot, renderedAt: Date) {
        self.pressureArtifactReadiness = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            renderedAt: renderedAt,
            metric: snapshot.modelArtifacts.pressureArtifactReadiness
        )
        self.pressureArtifactCatalog = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            metric: snapshot.modelArtifacts.pressureArtifactCatalog
        )
        self.recentPressureArtifacts = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            entries: snapshot.modelArtifacts.recentPressureArtifacts.entries
        )
    }
}

public struct OperatorDashboardOperatorContextSectionResponse: Content, Sendable {
    public var recentNotificationDebugEntries: RecentNotificationDebugEntriesResponse
    public var lastTouchedSeries: LastTouchedSeriesResponse

    init(snapshot: OperatorDashboardStoredSnapshot) {
        self.recentNotificationDebugEntries = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            entries: snapshot.recentNotificationDebugEntries
        )
        self.lastTouchedSeries = .init(
            refreshedAt: snapshot.fastRefreshedAt,
            entries: snapshot.touchedSeries
        )
    }
}

public struct PressureArtifactReadinessMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var status: String?
    public var runTime: Date?
    public var forecastHour: Int?
    public var validTime: Date?
    public var validTimeAgeSeconds: Int?
    public var fieldSetVersion: String?
    public var byteSize: Int64?
    public var source: String?
    public var updatedAt: Date?
    public var lastCheckedAt: Date?
    public var errorSummary: String?

    init(refreshedAt: Date?, renderedAt: Date, metric: StoredPressureArtifactDashboardReadinessMetric) {
        self.refreshedAt = refreshedAt
        self.status = metric.status
        self.runTime = metric.runTime
        self.forecastHour = metric.forecastHour
        self.validTime = metric.validTime
        self.validTimeAgeSeconds = OperatorDashboardCalculations.ageSeconds(
            since: metric.validTime,
            renderedAt: renderedAt
        )
        self.fieldSetVersion = metric.fieldSetVersion
        self.byteSize = metric.byteSize
        self.source = metric.source
        self.updatedAt = metric.updatedAt
        self.lastCheckedAt = metric.lastCheckedAt
        self.errorSummary = metric.errorSummary
    }
}

public struct PressureArtifactCatalogMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var totalCount: Int
    public var pendingCount: Int
    public var warmingCount: Int
    public var readyCount: Int
    public var failedCount: Int
    public var expiredCount: Int
    public var mostRecentFailureAt: Date?
    public var mostRecentFailureSummary: String?

    init(refreshedAt: Date?, metric: StoredPressureArtifactDashboardCatalogMetric) {
        self.refreshedAt = refreshedAt
        self.totalCount = metric.totalRowCount
        self.pendingCount = metric.pendingCount
        self.warmingCount = metric.warmingCount
        self.readyCount = metric.readyCount
        self.failedCount = metric.failedCount
        self.expiredCount = metric.expiredCount
        self.mostRecentFailureAt = metric.mostRecentFailureAt
        self.mostRecentFailureSummary = metric.mostRecentFailureSummary
    }
}

public struct PressureArtifactEntryResponse: Content, Sendable {
    public var runTime: Date
    public var forecastHour: Int
    public var validTime: Date
    public var product: String
    public var fieldSetVersion: String
    public var status: String
    public var byteSize: Int64?
    public var source: String
    public var updatedAt: Date?
    public var lastCheckedAt: Date?
    public var errorSummary: String?
}

public struct RecentPressureArtifactEntriesResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var entries: [PressureArtifactEntryResponse]

    init(refreshedAt: Date?, entries: [StoredPressureArtifactDashboardEntry]) {
        self.refreshedAt = refreshedAt
        self.entries = entries.map {
            .init(
                runTime: $0.runTime,
                forecastHour: $0.forecastHour,
                validTime: $0.validTime,
                product: $0.product,
                fieldSetVersion: $0.fieldSetVersion,
                status: $0.status,
                byteSize: $0.byteSize,
                source: $0.source,
                updatedAt: $0.updatedAt,
                lastCheckedAt: $0.lastCheckedAt,
                errorSummary: $0.errorSummary
            )
        }
    }
}

public struct IngestFreshnessMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var lastSuccessfulSweepAt: Date?
    public var timeSinceLastSuccessfulSweepSeconds: Int?
    public var lastAttemptAt: Date?
    public var recentAttemptLimit: Int
    public var recentSuccessCount: Int
    public var recentFailureCount: Int
    public var lastFailureAt: Date?
    public var lastFailureMessage: String?

    init(refreshedAt: Date?, renderedAt: Date, metric: StoredIngestFreshnessMetric) {
        self.refreshedAt = refreshedAt
        self.lastSuccessfulSweepAt = metric.lastSuccessfulCompletedAt
        self.timeSinceLastSuccessfulSweepSeconds = OperatorDashboardCalculations.ageSeconds(
            since: metric.lastSuccessfulCompletedAt,
            renderedAt: renderedAt
        )
        self.lastAttemptAt = metric.lastAttemptCompletedAt
        self.recentAttemptLimit = metric.recentAttemptLimit
        self.recentSuccessCount = metric.recentSuccessCount
        self.recentFailureCount = metric.recentFailureCount
        self.lastFailureAt = metric.lastFailureCompletedAt
        self.lastFailureMessage = metric.lastFailureMessage
    }
}

public struct PipelineBacklogMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var pendingTargetDispatchCount: Int
    public var oldestPendingTargetDispatchCreatedAt: Date?
    public var oldestPendingTargetDispatchAgeSeconds: Int?
    public var pendingNotificationDispatchCount: Int
    public var oldestPendingNotificationDispatchCreatedAt: Date?
    public var oldestPendingNotificationDispatchAgeSeconds: Int?

    init(refreshedAt: Date?, renderedAt: Date, metric: StoredPipelineBacklogMetric) {
        self.refreshedAt = refreshedAt
        self.pendingTargetDispatchCount = metric.pendingTargetDispatchCount
        self.oldestPendingTargetDispatchCreatedAt = metric.oldestPendingTargetDispatchCreatedAt
        self.oldestPendingTargetDispatchAgeSeconds = OperatorDashboardCalculations.ageSeconds(
            since: metric.oldestPendingTargetDispatchCreatedAt,
            renderedAt: renderedAt
        )
        self.pendingNotificationDispatchCount = metric.pendingNotificationDispatchCount
        self.oldestPendingNotificationDispatchCreatedAt = metric.oldestPendingNotificationDispatchCreatedAt
        self.oldestPendingNotificationDispatchAgeSeconds = OperatorDashboardCalculations.ageSeconds(
            since: metric.oldestPendingNotificationDispatchCreatedAt,
            renderedAt: renderedAt
        )
    }
}

public struct StuckClaimedRowsMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var thresholdSeconds: Int
    public var count: Int
    public var oldestClaimedCreatedAt: Date?
    public var oldestClaimedAgeSeconds: Int?

    init(refreshedAt: Date?, renderedAt: Date, metric: StoredStuckClaimedRowsMetric) {
        self.refreshedAt = refreshedAt
        self.thresholdSeconds = metric.thresholdSeconds
        self.count = metric.count
        self.oldestClaimedCreatedAt = metric.oldestClaimedCreatedAt
        self.oldestClaimedAgeSeconds = OperatorDashboardCalculations.ageSeconds(
            since: metric.oldestClaimedCreatedAt,
            renderedAt: renderedAt
        )
    }
}

public struct StaleActiveSeriesMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var graceSeconds: Int
    public var count: Int

    init(refreshedAt: Date?, metric: StoredStaleActiveSeriesMetric) {
        self.refreshedAt = refreshedAt
        self.graceSeconds = metric.graceSeconds
        self.count = metric.count
    }
}

public struct EndToEndLatencyMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var windowHours: Int
    public var successfulRevisionCount: Int
    public var p95Seconds: Double?

    init(refreshedAt: Date?, metric: StoredEndToEndLatencyMetric) {
        self.refreshedAt = refreshedAt
        self.windowHours = metric.windowHours
        self.successfulRevisionCount = metric.successfulRevisionCount
        self.p95Seconds = metric.p95Seconds
    }
}

public struct ReasonBreakdownResponse: Content, Sendable {
    public var reason: String
    public var count: Int
    public var rate: Double?

    init(reason: String, count: Int, denominator: Int) {
        self.reason = reason
        self.count = count
        self.rate = OperatorDashboardCalculations.rate(
            numerator: count,
            denominator: denominator
        )
    }
}

public struct APNsDeliveryMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var windowHours: Int
    public var sentCount: Int
    public var failedCount: Int
    public var successRate: Double?
    public var topFailureReasons: [ReasonBreakdownResponse]

    init(refreshedAt: Date?, metric: StoredAPNsDeliveryMetric) {
        let denominator = metric.sentCount + metric.failedCount
        self.refreshedAt = refreshedAt
        self.windowHours = metric.windowHours
        self.sentCount = metric.sentCount
        self.failedCount = metric.failedCount
        self.successRate = OperatorDashboardCalculations.rate(
            numerator: metric.sentCount,
            denominator: denominator
        )
        self.topFailureReasons = metric.topFailureReasons.map {
            .init(reason: $0.reason, count: $0.count, denominator: metric.failedCount)
        }
    }
}

public struct SendNoOpsMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var windowHours: Int
    public var totalAttemptCount: Int
    public var noOpAttemptCount: Int
    public var noOpRate: Double?
    public var reasons: [ReasonBreakdownResponse]

    init(refreshedAt: Date?, metric: StoredSendNoOpsMetric) {
        self.refreshedAt = refreshedAt
        self.windowHours = metric.windowHours
        self.totalAttemptCount = metric.totalAttemptCount
        self.noOpAttemptCount = metric.noOpAttemptCount
        self.noOpRate = OperatorDashboardCalculations.rate(
            numerator: metric.noOpAttemptCount,
            denominator: metric.totalAttemptCount
        )
        self.reasons = metric.reasons.map {
            .init(reason: $0.reason, count: $0.count, denominator: metric.totalAttemptCount)
        }
    }
}

public struct ZeroCandidateRateMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var windowHours: Int
    public var candidateResolutionAttemptCount: Int
    public var zeroCandidateAttemptCount: Int
    public var zeroCandidateRate: Double?

    init(refreshedAt: Date?, metric: StoredZeroCandidateRateMetric) {
        self.refreshedAt = refreshedAt
        self.windowHours = metric.windowHours
        self.candidateResolutionAttemptCount = metric.candidateResolutionAttemptCount
        self.zeroCandidateAttemptCount = metric.zeroCandidateAttemptCount
        self.zeroCandidateRate = OperatorDashboardCalculations.rate(
            numerator: metric.zeroCandidateAttemptCount,
            denominator: metric.candidateResolutionAttemptCount
        )
    }
}

public struct TargetableCoverageBreakdownResponse: Content, Sendable {
    public var missingDeviceTokenCount: Int
    public var staleInstallationHeartbeatCount: Int
    public var stalePresenceCount: Int
    public var missingTargetingDataCount: Int
}

public struct TargetableCoverageMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var installationFreshnessSeconds: Int
    public var presenceFreshnessSeconds: Int
    public var activeSubscribedInstallationCount: Int
    public var targetableInstallationCount: Int
    public var targetableRate: Double?
    public var lossBreakdown: TargetableCoverageBreakdownResponse

    init(refreshedAt: Date?, metric: StoredTargetableCoverageMetric) {
        self.refreshedAt = refreshedAt
        self.installationFreshnessSeconds = metric.installationFreshnessSeconds
        self.presenceFreshnessSeconds = metric.presenceFreshnessSeconds
        self.activeSubscribedInstallationCount = metric.activeSubscribedInstallationCount
        self.targetableInstallationCount = metric.targetableInstallationCount
        self.targetableRate = OperatorDashboardCalculations.rate(
            numerator: metric.targetableInstallationCount,
            denominator: metric.activeSubscribedInstallationCount
        )
        self.lossBreakdown = .init(
            missingDeviceTokenCount: metric.lossBreakdown.missingDeviceTokenCount,
            staleInstallationHeartbeatCount: metric.lossBreakdown.staleInstallationHeartbeatCount,
            stalePresenceCount: metric.lossBreakdown.stalePresenceCount,
            missingTargetingDataCount: metric.lossBreakdown.missingTargetingDataCount
        )
    }
}

public struct H3DerivationMetricResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var windowHours: Int
    public var geometryBearingRevisionCount: Int
    public var successfulConversionCount: Int
    public var successRate: Double?
    public var p95ConversionSeconds: Double?

    init(refreshedAt: Date?, metric: StoredH3DerivationMetric) {
        self.refreshedAt = refreshedAt
        self.windowHours = metric.windowHours
        self.geometryBearingRevisionCount = metric.geometryBearingRevisionCount
        self.successfulConversionCount = metric.successfulConversionCount
        self.successRate = OperatorDashboardCalculations.rate(
            numerator: metric.successfulConversionCount,
            denominator: metric.geometryBearingRevisionCount
        )
        self.p95ConversionSeconds = metric.p95ConversionSeconds
    }
}

public struct RecentNotificationDebugEntryResponse: Content, Sendable {
    public var createdAt: Date
    public var seriesID: UUID
    public var eventName: String
    public var recordKind: String
    public var mode: String
    public var reason: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var ledgerStatus: String?
    public var apnsErrorCode: String?
}

public struct RecentNotificationDebugEntriesResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var entries: [RecentNotificationDebugEntryResponse]

    init(refreshedAt: Date?, entries: [StoredRecentNotificationDebugEntry]) {
        self.refreshedAt = refreshedAt
        self.entries = entries.map {
            .init(
                createdAt: $0.createdAt,
                seriesID: $0.seriesID,
                eventName: $0.eventName,
                recordKind: $0.recordKind,
                mode: $0.mode,
                reason: $0.reason,
                title: $0.title,
                subtitle: $0.subtitle,
                body: $0.body,
                ledgerStatus: $0.ledgerStatus,
                apnsErrorCode: $0.apnsErrorCode
            )
        }
    }
}

public struct TouchedSeriesEntryResponse: Content, Sendable {
    public var seriesID: UUID
    public var eventName: String
    public var state: String
    public var ugcCodes: [String]
    public var tornadoDetection: String?
    public var tornadoDamageThreat: String?
    public var currentRevisionUrn: String
    public var touchedAt: Date
    public var latestRevisionReceivedAt: Date?
    public var seriesUpdatedAt: Date?
}

public struct LastTouchedSeriesResponse: Content, Sendable {
    public var refreshedAt: Date?
    public var entries: [TouchedSeriesEntryResponse]

    init(refreshedAt: Date?, entries: [StoredTouchedSeriesEntry]) {
        self.refreshedAt = refreshedAt
        self.entries = entries.map {
            .init(
                seriesID: $0.seriesID,
                eventName: $0.eventName,
                state: $0.state,
                ugcCodes: $0.ugcCodes,
                tornadoDetection: $0.tornadoDetection,
                tornadoDamageThreat: $0.tornadoDamageThreat,
                currentRevisionUrn: $0.currentRevisionUrn,
                touchedAt: $0.touchedAt,
                latestRevisionReceivedAt: $0.latestRevisionReceivedAt,
                seriesUpdatedAt: $0.seriesUpdatedAt
            )
        }
    }
}

enum OperatorDashboardCalculations {
    static func ageSeconds(since date: Date?, renderedAt: Date) -> Int? {
        guard let date else { return nil }
        return max(0, Int(renderedAt.timeIntervalSince(date)))
    }

    static func rate(numerator: Int, denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }
}
