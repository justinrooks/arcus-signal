import Fluent
import FluentSQL
import Foundation
import Queues
import Vapor
import ArcusCore

struct RefreshOperatorDashboardSnapshotScheduledJob: AsyncScheduledJob {
    func run(context: QueueContext) async throws {
        try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: context.application)
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

struct OperatorDashboardSnapshotRefresher {
    func refreshIfDue(
        on app: Application,
        forceAll: Bool = false,
        now: Date = .now
    ) async throws {
        guard let sql = app.db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        var snapshot = try await app.operatorDashboardSnapshotStore.load(on: app.db) ?? .empty(now: now)
        let fastDue = forceAll || shouldRefresh(snapshot.fastRefreshedAt, intervalSeconds: OperatorDashboardConfig.fastRefreshIntervalSeconds, now: now)
        let standardDue = forceAll || shouldRefresh(snapshot.standardRefreshedAt, intervalSeconds: OperatorDashboardConfig.standardRefreshIntervalSeconds, now: now)
        let slowDue = forceAll || shouldRefresh(snapshot.slowRefreshedAt, intervalSeconds: OperatorDashboardConfig.slowRefreshIntervalSeconds, now: now)

        guard fastDue || standardDue || slowDue || forceAll else {
            return
        }

        if fastDue {
            snapshot.ingestFreshness = try await loadIngestFreshness(on: app.db)
            snapshot.pipelineBacklog = try await loadPipelineBacklog(on: app.db)
            snapshot.stuckClaimedRows = try await loadStuckClaimedRows(on: app.db, now: now)
            snapshot.modelArtifacts = try await loadPressureArtifactCatalog(on: app, sql: sql, now: now)
            snapshot.recentNotificationDebugEntries = try await loadRecentNotificationDebugEntries(on: sql)
            snapshot.touchedSeries = try await loadTouchedSeries(on: sql)
            snapshot.fastRefreshedAt = now
        }

        if standardDue {
            snapshot.staleActiveSeries = try await loadStaleActiveSeries(on: sql, now: now)
            snapshot.sendNoOps = try await loadSendNoOps(on: sql, now: now)
            snapshot.zeroCandidateRate = try await loadZeroCandidateRate(on: sql, now: now)
            snapshot.h3Derivation = try await loadH3Derivation(on: sql, now: now)
            snapshot.standardRefreshedAt = now
        }

        if slowDue {
            snapshot.endToEndLatency = try await loadEndToEndLatency(on: sql, now: now)
            snapshot.apnsDelivery = try await loadAPNsDelivery(on: sql, now: now)
            snapshot.targetableCoverage = try await loadTargetableCoverage(on: sql, now: now)
            snapshot.slowRefreshedAt = now
        }

        snapshot.generatedAt = now
        try await app.operatorDashboardSnapshotStore.save(snapshot, on: app.db)
    }

    private func shouldRefresh(_ refreshedAt: Date?, intervalSeconds: Int, now: Date) -> Bool {
        guard let refreshedAt else { return true }
        return now.timeIntervalSince(refreshedAt) >= Double(intervalSeconds)
    }

    private func loadIngestFreshness(on database: any Database) async throws -> StoredIngestFreshnessMetric {
        let recentRuns = try await IngestSweepRunModel.query(on: database)
            .sort(\.$completedAt, .descending)
            .limit(OperatorDashboardConfig.ingestRecentAttemptLimit)
            .all()

        let lastSuccessful = recentRuns.first { $0.status == IngestSweepRunStatus.succeeded.rawValue }
        let lastFailure = recentRuns.first { $0.status == IngestSweepRunStatus.failed.rawValue }

        return .init(
            recentAttemptLimit: OperatorDashboardConfig.ingestRecentAttemptLimit,
            lastSuccessfulCompletedAt: lastSuccessful?.completedAt,
            lastAttemptCompletedAt: recentRuns.first?.completedAt,
            recentSuccessCount: recentRuns.filter { $0.status == IngestSweepRunStatus.succeeded.rawValue }.count,
            recentFailureCount: recentRuns.filter { $0.status == IngestSweepRunStatus.failed.rawValue }.count,
            lastFailureCompletedAt: lastFailure?.completedAt,
            lastFailureMessage: lastFailure?.errorMessage
        )
    }

    private func loadPipelineBacklog(on database: any Database) async throws -> StoredPipelineBacklogMetric {
        let pendingTargetQuery = ArcusTargetDispatchOutboxModel.query(on: database)
            .filter(\.$dispatched == nil)
        let pendingNotificationQuery = ArcusNotificationOutboxModel.query(on: database)
            .filter(\.$state == "ready")

        let oldestTarget = try await pendingTargetQuery.copy().sort(\.$created, .ascending).first()
        let oldestNotification = try await pendingNotificationQuery.copy().sort(\.$created, .ascending).first()

        return .init(
            pendingTargetDispatchCount: try await pendingTargetQuery.count(),
            oldestPendingTargetDispatchCreatedAt: oldestTarget?.created,
            pendingNotificationDispatchCount: try await pendingNotificationQuery.count(),
            oldestPendingNotificationDispatchCreatedAt: oldestNotification?.created
        )
    }

    private func loadStuckClaimedRows(on database: any Database, now: Date) async throws -> StoredStuckClaimedRowsMetric {
        let cutoff = now.addingTimeInterval(-Double(OperatorDashboardConfig.claimedStuckThresholdSeconds))
        let query = NotificationLedgerModel.query(on: database)
            .group(.and) { group in
                group.filter(\.$status == "claimed")
                group.filter(\.$created <= cutoff)
            }

        let oldestClaim = try await query.copy().sort(\.$created, .ascending).first()

        return .init(
            thresholdSeconds: OperatorDashboardConfig.claimedStuckThresholdSeconds,
            count: try await query.count(),
            oldestClaimedCreatedAt: oldestClaim?.created
        )
    }

    private func loadStaleActiveSeries(on sql: any SQLDatabase, now: Date) async throws -> StoredStaleActiveSeriesMetric {
        let cutoff = now.addingTimeInterval(-Double(OperatorDashboardConfig.staleActiveSeriesGraceSeconds))
        let row = try await sql.raw("""
            SELECT COUNT(*) AS "count"
            FROM arcus_series
            WHERE state = 'active'
              AND COALESCE(ends, expires) IS NOT NULL
              AND COALESCE(ends, expires) < \(bind: cutoff)
        """).first(decoding: SingleCountRow.self)

        return .init(
            graceSeconds: OperatorDashboardConfig.staleActiveSeriesGraceSeconds,
            count: row.map { Int($0.count) } ?? 0
        )
    }

    private func loadEndToEndLatency(on sql: any SQLDatabase, now: Date) async throws -> StoredEndToEndLatencyMetric {
        let windowStart = now.addingTimeInterval(-Double(OperatorDashboardConfig.rollingWindowHours * 60 * 60))
        let row = try await sql.raw("""
            WITH first_success AS (
                SELECT revision_urn, MIN(completed_at) AS first_completed_at
                FROM notification_ledger
                WHERE status = 'sent'
                  AND completed_at IS NOT NULL
                GROUP BY revision_urn
            ),
            windowed AS (
                SELECT EXTRACT(EPOCH FROM (f.first_completed_at - r.received)) AS latency_seconds
                FROM first_success f
                JOIN alert_revisions r ON r.revision_urn = f.revision_urn
                WHERE r.received >= \(bind: windowStart)
                  AND f.first_completed_at >= r.received
            )
            SELECT COUNT(*) AS "successfulRevisionCount",
                   PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY latency_seconds) AS "p95Seconds"
            FROM windowed
        """).first(decoding: LatencyAggregateRow.self)

        return .init(
            windowHours: OperatorDashboardConfig.rollingWindowHours,
            successfulRevisionCount: row.map { Int($0.successfulRevisionCount) } ?? 0,
            p95Seconds: row?.p95Seconds
        )
    }

    private func loadAPNsDelivery(on sql: any SQLDatabase, now: Date) async throws -> StoredAPNsDeliveryMetric {
        let windowStart = now.addingTimeInterval(-Double(OperatorDashboardConfig.rollingWindowHours * 60 * 60))
        let aggregate = try await sql.raw("""
            SELECT
                COUNT(*) FILTER (WHERE status = 'sent') AS "sentCount",
                COUNT(*) FILTER (WHERE status = 'failed') AS "failedCount"
            FROM notification_ledger
            WHERE completed_at >= \(bind: windowStart)
              AND status IN ('sent', 'failed')
        """).first(decoding: DeliveryAggregateRow.self)

        let reasons = try await sql.raw("""
            SELECT COALESCE(apns_error_code, 'unknown') AS "reason",
                   COUNT(*) AS "count"
            FROM notification_ledger
            WHERE completed_at >= \(bind: windowStart)
              AND status = 'failed'
            GROUP BY COALESCE(apns_error_code, 'unknown')
            ORDER BY COUNT(*) DESC, COALESCE(apns_error_code, 'unknown') ASC
            LIMIT \(bind: OperatorDashboardConfig.topFailureReasonLimit)
        """).all(decoding: ReasonAggregateRow.self)

        return .init(
            windowHours: OperatorDashboardConfig.rollingWindowHours,
            sentCount: aggregate.map { Int($0.sentCount) } ?? 0,
            failedCount: aggregate.map { Int($0.failedCount) } ?? 0,
            topFailureReasons: reasons.map { .init(reason: $0.reason, count: Int($0.count)) }
        )
    }

    private func loadSendNoOps(on sql: any SQLDatabase, now: Date) async throws -> StoredSendNoOpsMetric {
        let windowStart = now.addingTimeInterval(-Double(OperatorDashboardConfig.rollingWindowHours * 60 * 60))
        let aggregate = try await sql.raw("""
            SELECT
                COUNT(*) AS "totalAttemptCount",
                COUNT(*) FILTER (WHERE outcome = 'no_op') AS "noOpAttemptCount"
            FROM notification_send_attempts
            WHERE attempted_at >= \(bind: windowStart)
        """).first(decoding: SendAttemptAggregateRow.self)

        let reasons = try await sql.raw("""
            SELECT no_op_reason AS "reason",
                   COUNT(*) AS "count"
            FROM notification_send_attempts
            WHERE attempted_at >= \(bind: windowStart)
              AND outcome = 'no_op'
              AND no_op_reason IS NOT NULL
            GROUP BY no_op_reason
            ORDER BY COUNT(*) DESC, no_op_reason ASC
        """).all(decoding: ReasonAggregateRow.self)

        return .init(
            windowHours: OperatorDashboardConfig.rollingWindowHours,
            totalAttemptCount: aggregate.map { Int($0.totalAttemptCount) } ?? 0,
            noOpAttemptCount: aggregate.map { Int($0.noOpAttemptCount) } ?? 0,
            reasons: reasons.map { .init(reason: $0.reason, count: Int($0.count)) }
        )
    }

    private func loadZeroCandidateRate(on sql: any SQLDatabase, now: Date) async throws -> StoredZeroCandidateRateMetric {
        let windowStart = now.addingTimeInterval(-Double(OperatorDashboardConfig.rollingWindowHours * 60 * 60))
        let aggregate = try await sql.raw("""
            SELECT
                COUNT(*) FILTER (WHERE candidate_resolution_reached = TRUE) AS "candidateResolutionAttemptCount",
                COUNT(*) FILTER (WHERE candidate_resolution_reached = TRUE AND candidate_count = 0) AS "zeroCandidateAttemptCount"
            FROM notification_send_attempts
            WHERE attempted_at >= \(bind: windowStart)
        """).first(decoding: ZeroCandidateAggregateRow.self)

        return .init(
            windowHours: OperatorDashboardConfig.rollingWindowHours,
            candidateResolutionAttemptCount: aggregate.map { Int($0.candidateResolutionAttemptCount) } ?? 0,
            zeroCandidateAttemptCount: aggregate.map { Int($0.zeroCandidateAttemptCount) } ?? 0
        )
    }

    func loadTargetableCoverage(on sql: any SQLDatabase, now: Date) async throws -> StoredTargetableCoverageMetric {
        let installationCutoff = now.addingTimeInterval(-Double(OperatorDashboardConfig.installationFreshnessThresholdSeconds))
        let presenceCutoff = now.addingTimeInterval(-Double(OperatorDashboardConfig.presenceFreshnessThresholdSeconds))
        let hardStalePresenceCutoff = now.addingTimeInterval(-LocationFreshnessPolicy.hardStaleThreshold)
        let row = try await sql.raw("""
            SELECT
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE AND i.is_subscribed = TRUE
                ) AS "activeSubscribedInstallationCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND i.last_seen_at >= \(bind: installationCutoff)
                      AND p.installation_id IS NOT NULL
                      AND p.captured_at >= \(bind: presenceCutoff)
                      AND (
                          p.h3_cell IS NOT NULL
                          OR COALESCE(BTRIM(p.county), '') <> ''
                          OR COALESCE(BTRIM(p.zone), '') <> ''
                          OR COALESCE(BTRIM(p.fire_zone), '') <> ''
                      )
                ) AS "targetableInstallationCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token = ''
                ) AS "missingDeviceTokenCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND i.last_seen_at < \(bind: installationCutoff)
                ) AS "staleInstallationHeartbeatCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND i.last_seen_at >= \(bind: installationCutoff)
                      AND (
                          p.installation_id IS NULL
                          OR p.captured_at < \(bind: presenceCutoff)
                      )
                ) AS "stalePresenceCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND i.last_seen_at >= \(bind: installationCutoff)
                      AND p.installation_id IS NOT NULL
                      AND p.captured_at >= \(bind: presenceCutoff)
                      AND NOT (
                          p.h3_cell IS NOT NULL
                          OR COALESCE(BTRIM(p.county), '') <> ''
                          OR COALESCE(BTRIM(p.zone), '') <> ''
                          OR COALESCE(BTRIM(p.fire_zone), '') <> ''
                      )
                ) AS "missingTargetingDataCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND p.installation_id IS NOT NULL
                      AND p.captured_at >= \(bind: hardStalePresenceCutoff)
                      AND (
                          p.h3_cell IS NOT NULL
                          OR COALESCE(BTRIM(p.county), '') <> ''
                          OR COALESCE(BTRIM(p.zone), '') <> ''
                          OR COALESCE(BTRIM(p.fire_zone), '') <> ''
                      )
                ) AS "candidateQueryEligibleInstallationCount",
                COUNT(*) FILTER (
                    WHERE i.is_active = TRUE
                      AND i.is_subscribed = TRUE
                      AND i.apns_device_token <> ''
                      AND p.installation_id IS NOT NULL
                      AND p.captured_at < \(bind: hardStalePresenceCutoff)
                      AND (
                          p.h3_cell IS NOT NULL
                          OR COALESCE(BTRIM(p.county), '') <> ''
                          OR COALESCE(BTRIM(p.zone), '') <> ''
                          OR COALESCE(BTRIM(p.fire_zone), '') <> ''
                      )
                ) AS "hardStalePresenceCount"
            FROM device_installations i
            LEFT JOIN device_presence p
              ON p.installation_id = i.installation_id
        """).first(decoding: TargetableCoverageRow.self)

        return .init(
            installationFreshnessSeconds: OperatorDashboardConfig.installationFreshnessThresholdSeconds,
            presenceFreshnessSeconds: OperatorDashboardConfig.presenceFreshnessThresholdSeconds,
            hardStalePresenceThresholdSeconds: Int(LocationFreshnessPolicy.hardStaleThreshold),
            activeSubscribedInstallationCount: row.map { Int($0.activeSubscribedInstallationCount) } ?? 0,
            targetableInstallationCount: row.map { Int($0.targetableInstallationCount) } ?? 0,
            candidateQueryEligibleInstallationCount: row.map { Int($0.candidateQueryEligibleInstallationCount) } ?? 0,
            hardStalePresenceCount: row.map { Int($0.hardStalePresenceCount) } ?? 0,
            lossBreakdown: .init(
                missingDeviceTokenCount: row.map { Int($0.missingDeviceTokenCount) } ?? 0,
                staleInstallationHeartbeatCount: row.map { Int($0.staleInstallationHeartbeatCount) } ?? 0,
                stalePresenceCount: row.map { Int($0.stalePresenceCount) } ?? 0,
                missingTargetingDataCount: row.map { Int($0.missingTargetingDataCount) } ?? 0
            )
        )
    }

    private func loadH3Derivation(on sql: any SQLDatabase, now: Date) async throws -> StoredH3DerivationMetric {
        let windowStart = now.addingTimeInterval(-Double(OperatorDashboardConfig.rollingWindowHours * 60 * 60))
        let row = try await sql.raw("""
            WITH base AS (
                SELECT created, completed, result
                FROM target_dispatch_outbox
                WHERE created >= \(bind: windowStart)
            ),
            successful AS (
                SELECT EXTRACT(EPOCH FROM (completed - created)) AS conversion_seconds
                FROM base
                WHERE result = 'succeeded'
                  AND completed IS NOT NULL
            )
            SELECT
                (SELECT COUNT(*) FROM base) AS "geometryBearingRevisionCount",
                (SELECT COUNT(*) FROM base WHERE result = 'succeeded') AS "successfulConversionCount",
                (SELECT PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY conversion_seconds) FROM successful) AS "p95ConversionSeconds"
        """).first(decoding: H3AggregateRow.self)

        return .init(
            windowHours: OperatorDashboardConfig.rollingWindowHours,
            geometryBearingRevisionCount: row.map { Int($0.geometryBearingRevisionCount) } ?? 0,
            successfulConversionCount: row.map { Int($0.successfulConversionCount) } ?? 0,
            p95ConversionSeconds: row?.p95ConversionSeconds
        )
    }

    private func loadPressureArtifactCatalog(
        on app: Application,
        sql: any SQLDatabase,
        now: Date
    ) async throws -> StoredPressureArtifactDashboardMetric {
        let fieldSetVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion.rawValue
        let aggregate = try await sql.raw("""
            SELECT
                COUNT(*) AS "totalRowCount",
                COUNT(*) FILTER (WHERE status = 'pending') AS "pendingCount",
                COUNT(*) FILTER (WHERE status = 'warming') AS "warmingCount",
                COUNT(*) FILTER (WHERE status = 'ready') AS "readyCount",
                COUNT(*) FILTER (WHERE status = 'failed') AS "failedCount",
                COUNT(*) FILTER (WHERE status = 'expired') AS "expiredCount"
            FROM pressure_artifact_catalog
            WHERE product = 'wrfprsf'
              AND field_set_version = \(bind: fieldSetVersion)
        """).first(decoding: PressureArtifactCatalogAggregateRow.self)

        let recentRows = try await sql.raw("""
            SELECT
                run_time AS "runTime",
                forecast_hour AS "forecastHour",
                valid_time AS "validTime",
                product,
                field_set_version AS "fieldSetVersion",
                status,
                byte_size AS "byteSize",
                source,
                created_at AS "createdAt",
                updated_at AS "updatedAt",
                last_checked_at AS "lastCheckedAt",
                error_summary AS "errorSummary"
            FROM pressure_artifact_catalog
            WHERE product = 'wrfprsf'
              AND field_set_version = \(bind: fieldSetVersion)
            ORDER BY valid_time DESC, updated_at DESC
            LIMIT \(bind: 5)
        """).all(decoding: PressureArtifactRow.self)

        let readiness = try await loadPressureArtifactReadiness(
            on: app,
            sql: sql,
            recentRows: recentRows,
            now: now
        )

        let latestFailedRow = try await sql.raw("""
            SELECT
                run_time AS "runTime",
                forecast_hour AS "forecastHour",
                valid_time AS "validTime",
                product,
                field_set_version AS "fieldSetVersion",
                status,
                byte_size AS "byteSize",
                source,
                created_at AS "createdAt",
                updated_at AS "updatedAt",
                last_checked_at AS "lastCheckedAt",
                error_summary AS "errorSummary"
            FROM pressure_artifact_catalog
            WHERE product = 'wrfprsf'
              AND field_set_version = \(bind: fieldSetVersion)
              AND status = 'failed'
            ORDER BY updated_at DESC, valid_time DESC
            LIMIT 1
        """).first(decoding: PressureArtifactRow.self)

        let latestFailure = latestFailedRow ?? recentRows.first(where: { $0.status == PressureArtifactCatalogStatus.failed.rawValue })

        return .init(
            pressureArtifactReadiness: readiness,
            pressureArtifactCatalog: .init(
                refreshedAt: now,
                totalRowCount: aggregate.map { Int($0.totalRowCount) } ?? 0,
                pendingCount: aggregate.map { Int($0.pendingCount) } ?? 0,
                warmingCount: aggregate.map { Int($0.warmingCount) } ?? 0,
                readyCount: aggregate.map { Int($0.readyCount) } ?? 0,
                failedCount: aggregate.map { Int($0.failedCount) } ?? 0,
                expiredCount: aggregate.map { Int($0.expiredCount) } ?? 0,
                mostRecentFailureAt: latestFailure?.updatedAt,
                mostRecentFailureSummary: latestFailure?.errorSummary
            ),
            recentPressureArtifacts: .init(
                refreshedAt: now,
                entries: recentRows.map {
                    .init(
                        runTime: $0.runTime,
                        forecastHour: $0.forecastHour,
                        validTime: $0.validTime,
                        product: $0.product,
                        fieldSetVersion: $0.fieldSetVersion,
                        status: $0.status,
                        byteSize: $0.byteSize,
                        source: $0.source,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt,
                        lastCheckedAt: $0.lastCheckedAt,
                        errorSummary: $0.errorSummary
                    )
                }
            )
        )
    }

    private func loadPressureArtifactReadiness(
        on app: Application,
        sql: any SQLDatabase,
        recentRows: [PressureArtifactRow],
        now: Date
    ) async throws -> StoredPressureArtifactDashboardReadinessMetric {
        let dateProvider = FixedStormSetupDateProvider(nowDate: now)
        let hrrrRunResolver = DefaultHrrrRunResolver(dateProvider: dateProvider)
        let blockingWorkExecutor = NIOThreadPoolPressureArtifactBlockingWorkExecutor(
            threadPool: app.threadPool
        )
        let lookupService = DefaultPressureArtifactCatalogLookupService(
            database: app.db,
            blockingWorkExecutor: blockingWorkExecutor,
            maximumStaleAgeSeconds: app.stormSetupConfiguration.pressureArtifactMaxStaleAgeSeconds,
            logger: app.logger
        )
        let runResolution = hrrrRunResolver.resolveRunCandidates()
        let pressureResolution = HrrrRunResolution(
            targetValidTime: runResolution.targetValidTime,
            candidates: runResolution.candidates.map {
                HrrrSurfaceToPressureCandidatePolicy.makePressureCandidate(from: $0)
            }
        )
        let staleCutoff = pressureResolution.targetValidTime.addingTimeInterval(
            -app.stormSetupConfiguration.pressureArtifactMaxStaleAgeSeconds
        )

        for candidate in pressureResolution.candidates {
            if let readyArtifact = try await lookupService.readyArtifact(for: candidate) {
                let row = try await loadPressureArtifactRow(
                    on: sql,
                    runTime: readyArtifact.runTime,
                    forecastHour: readyArtifact.forecastHour,
                    product: readyArtifact.product,
                    fieldSetVersion: readyArtifact.fieldSetVersion
                )

                return makePressureArtifactReadinessMetric(
                    selectionOutcome: .exact,
                    status: PressureArtifactCatalogStatus.ready.rawValue,
                    readinessReason: nil,
                    artifact: readyArtifact,
                    row: row,
                    refreshedAt: now
                )
            }
        }

        if let staleArtifact = try await lookupService.staleArtifact(for: pressureResolution) {
            let row = try await loadPressureArtifactRow(
                on: sql,
                runTime: staleArtifact.runTime,
                forecastHour: staleArtifact.forecastHour,
                product: staleArtifact.product,
                fieldSetVersion: staleArtifact.fieldSetVersion
            )

            return makePressureArtifactReadinessMetric(
                selectionOutcome: .stale,
                status: PressureArtifactCatalogStatus.ready.rawValue,
                readinessReason: "Bounded stale fallback selected after all exact candidates missed.",
                artifact: staleArtifact,
                row: row,
                refreshedAt: now
            )
        }

        let newestRow = recentRows.first
        return makePressureArtifactReadinessMetric(
            selectionOutcome: .unavailable,
            status: newestRow?.status,
            readinessReason: makeUnavailableReadinessReason(for: newestRow, staleCutoff: staleCutoff),
            artifact: nil,
            row: newestRow,
            refreshedAt: now
        )
    }

    private func loadPressureArtifactRow(
        on sql: any SQLDatabase,
        runTime: Date,
        forecastHour: Int,
        product: HrrrProduct,
        fieldSetVersion: HrrrFieldSetVersion
    ) async throws -> PressureArtifactRow? {
        try await sql.raw("""
            SELECT
                run_time AS "runTime",
                forecast_hour AS "forecastHour",
                valid_time AS "validTime",
                product,
                field_set_version AS "fieldSetVersion",
                status,
                byte_size AS "byteSize",
                source,
                created_at AS "createdAt",
                updated_at AS "updatedAt",
                last_checked_at AS "lastCheckedAt",
                error_summary AS "errorSummary"
            FROM pressure_artifact_catalog
            WHERE run_time = \(bind: runTime)
              AND forecast_hour = \(bind: forecastHour)
              AND product = \(bind: product.rawValue)
              AND field_set_version = \(bind: fieldSetVersion.rawValue)
            LIMIT 1
        """).first(decoding: PressureArtifactRow.self)
    }

    private func makePressureArtifactReadinessMetric(
        selectionOutcome: PressureArtifactReadinessSelectionOutcome,
        status: String?,
        readinessReason: String?,
        artifact: PressureArtifactCatalogReadyArtifact?,
        row: PressureArtifactRow?,
        refreshedAt: Date
    ) -> StoredPressureArtifactDashboardReadinessMetric {
        let usableStatus = selectionOutcome == .unavailable ? status : PressureArtifactCatalogStatus.ready.rawValue

        return .init(
            refreshedAt: refreshedAt,
            selectionOutcome: selectionOutcome,
            status: usableStatus,
            runTime: artifact?.runTime ?? row?.runTime,
            forecastHour: artifact?.forecastHour ?? row?.forecastHour,
            validTime: artifact?.validTime ?? row?.validTime,
            fieldSetVersion: artifact?.fieldSetVersion.rawValue ?? row?.fieldSetVersion,
            byteSize: artifact?.byteSize ?? row?.byteSize,
            source: row?.source ?? PressureArtifactCatalogSource.unknown.rawValue,
            updatedAt: row?.updatedAt,
            lastCheckedAt: row?.lastCheckedAt,
            errorSummary: row?.errorSummary,
            readinessReason: readinessReason
        )
    }

    private func makeUnavailableReadinessReason(
        for row: PressureArtifactRow?,
        staleCutoff: Date
    ) -> String? {
        guard let row else {
            return "No current-version catalog artifact exists."
        }

        switch row.status {
        case PressureArtifactCatalogStatus.ready.rawValue:
            if row.validTime < staleCutoff {
                return "Newest catalog row is ready, but it is outside the bounded stale window."
            }
            return "Newest catalog row is ready, but no usable local artifact file was found."
        case PressureArtifactCatalogStatus.pending.rawValue:
            return "Newest catalog row is pending."
        case PressureArtifactCatalogStatus.warming.rawValue:
            return "Newest catalog row is warming."
        case PressureArtifactCatalogStatus.failed.rawValue:
            if let errorSummary = row.errorSummary, errorSummary.isEmpty == false {
                return "Newest catalog row is failed: \(errorSummary)."
            }
            return "Newest catalog row is failed."
        case PressureArtifactCatalogStatus.expired.rawValue:
            return "Newest catalog row is expired."
        default:
            return "Newest catalog row is \(row.status)."
        }
    }

    private func loadRecentNotificationDebugEntries(on sql: any SQLDatabase) async throws -> [StoredRecentNotificationDebugEntry] {
        let rows = try await sql.raw("""
            SELECT
                d.created AS "createdAt",
                d.series_id AS "seriesID",
                COALESCE(s.event, s.headline, s.title, 'Unknown Alert') AS "eventName",
                d.record_kind AS "recordKind",
                d.mode AS "mode",
                d.reason AS "reason",
                d.title AS "title",
                d.subtitle AS "subtitle",
                d.body AS "body",
                l.status AS "ledgerStatus",
                l.apns_error_code AS "apnsErrorCode"
            FROM notification_debug d
            JOIN arcus_series s ON s.id = d.series_id
            LEFT JOIN notification_ledger l ON l.id = d.notification_ledger_id
            ORDER BY d.created DESC
            LIMIT \(bind: OperatorDashboardConfig.recentNotificationDebugLimit)
        """).all(decoding: RecentNotificationDebugRow.self)

        return rows.map {
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

    private func loadTouchedSeries(on sql: any SQLDatabase) async throws -> [StoredTouchedSeriesEntry] {
        let rows = try await sql.raw("""
            WITH latest_revision AS (
                SELECT series_id, MAX(received) AS latest_revision_received_at
                FROM alert_revisions
                GROUP BY series_id
            )
            SELECT
                s.id AS "seriesID",
                s.event AS "eventName",
                s.state AS "state",
                s.ugc_codes AS "ugcCodes",
                s.tornado_detection AS "tornadoDetection",
                s.tornado_damage_threat AS "tornadoDamageThreat",
                s.current_revision_urn AS "currentRevisionUrn",
                GREATEST(
                    COALESCE(l.latest_revision_received_at, TIMESTAMP 'epoch'),
                    COALESCE(s.updated, TIMESTAMP 'epoch')
                ) AS "touchedAt",
                l.latest_revision_received_at AS "latestRevisionReceivedAt",
                s.updated AS "seriesUpdatedAt"
            FROM arcus_series s
            LEFT JOIN latest_revision l
              ON l.series_id = s.id
            ORDER BY "touchedAt" DESC, s.id ASC
            LIMIT \(bind: OperatorDashboardConfig.touchedSeriesLimit)
        """).all(decoding: TouchedSeriesRow.self)

        return rows.map {
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

private struct SingleCountRow: Decodable {
    let count: Int64
}

private struct LatencyAggregateRow: Decodable {
    let successfulRevisionCount: Int64
    let p95Seconds: Double?
}

private struct DeliveryAggregateRow: Decodable {
    let sentCount: Int64
    let failedCount: Int64
}

private struct SendAttemptAggregateRow: Decodable {
    let totalAttemptCount: Int64
    let noOpAttemptCount: Int64
}

private struct ZeroCandidateAggregateRow: Decodable {
    let candidateResolutionAttemptCount: Int64
    let zeroCandidateAttemptCount: Int64
}

private struct ReasonAggregateRow: Decodable {
    let reason: String
    let count: Int64
}

private struct PressureArtifactCatalogAggregateRow: Decodable {
    let totalRowCount: Int64
    let pendingCount: Int64
    let warmingCount: Int64
    let readyCount: Int64
    let failedCount: Int64
    let expiredCount: Int64
}

private struct PressureArtifactRow: Decodable {
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let product: String
    let fieldSetVersion: String
    let status: String
    let byteSize: Int64?
    let source: String
    let createdAt: Date?
    let updatedAt: Date?
    let lastCheckedAt: Date?
    let errorSummary: String?
}

private struct TargetableCoverageRow: Decodable {
    let activeSubscribedInstallationCount: Int64
    let targetableInstallationCount: Int64
    let missingDeviceTokenCount: Int64
    let staleInstallationHeartbeatCount: Int64
    let stalePresenceCount: Int64
    let missingTargetingDataCount: Int64
    let candidateQueryEligibleInstallationCount: Int64
    let hardStalePresenceCount: Int64
}

private struct H3AggregateRow: Decodable {
    let geometryBearingRevisionCount: Int64
    let successfulConversionCount: Int64
    let p95ConversionSeconds: Double?
}

private struct RecentNotificationDebugRow: Decodable {
    let createdAt: Date
    let seriesID: UUID
    let eventName: String
    let recordKind: String
    let mode: String
    let reason: String
    let title: String
    let subtitle: String
    let body: String
    let ledgerStatus: String?
    let apnsErrorCode: String?
}

private struct TouchedSeriesRow: Decodable {
    let seriesID: UUID
    let eventName: String
    let state: String
    let ugcCodes: [String]
    let tornadoDetection: String?
    let tornadoDamageThreat: String?
    let currentRevisionUrn: String
    let touchedAt: Date
    let latestRevisionReceivedAt: Date?
    let seriesUpdatedAt: Date?
}
