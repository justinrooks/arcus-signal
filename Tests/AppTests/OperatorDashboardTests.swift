@testable import App
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Operator dashboard", .serialized)
struct OperatorDashboardTests {
    private struct StubSnapshotStore: OperatorDashboardSnapshotStore {
        let snapshot: OperatorDashboardStoredSnapshot?

        func load(on database: any Database) async throws -> OperatorDashboardStoredSnapshot? {
            snapshot
        }

        func save(_ snapshot: OperatorDashboardStoredSnapshot, on database: any Database) async throws {
            _ = snapshot
        }
    }

    private func withApp(
        test: (Application) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func isoDate(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            fatalError("Invalid ISO8601 date in test fixture: \(value)")
        }
        return date
    }

    private func makeSnapshot() -> OperatorDashboardStoredSnapshot {
        .init(
            generatedAt: isoDate("2026-04-10T12:00:00Z"),
            fastRefreshedAt: isoDate("2026-04-10T12:00:00Z"),
            standardRefreshedAt: isoDate("2026-04-10T11:59:30Z"),
            slowRefreshedAt: isoDate("2026-04-10T11:57:00Z"),
            ingestFreshness: .init(
                recentAttemptLimit: 60,
                lastSuccessfulCompletedAt: isoDate("2026-04-10T11:55:00Z"),
                lastAttemptCompletedAt: isoDate("2026-04-10T12:00:00Z"),
                recentSuccessCount: 58,
                recentFailureCount: 2,
                lastFailureCompletedAt: isoDate("2026-04-10T11:31:00Z"),
                lastFailureMessage: "temporary upstream timeout"
            ),
            pipelineBacklog: .init(
                pendingTargetDispatchCount: 2,
                oldestPendingTargetDispatchCreatedAt: isoDate("2026-04-10T11:54:00Z"),
                pendingNotificationDispatchCount: 4,
                oldestPendingNotificationDispatchCreatedAt: isoDate("2026-04-10T11:58:00Z")
            ),
            stuckClaimedRows: .init(
                thresholdSeconds: 300,
                count: 3,
                oldestClaimedCreatedAt: isoDate("2026-04-10T11:48:00Z")
            ),
            staleActiveSeries: .init(
                graceSeconds: 900,
                count: 5
            ),
            endToEndLatency: .init(
                windowHours: 24,
                successfulRevisionCount: 22,
                p95Seconds: 91
            ),
            apnsDelivery: .init(
                windowHours: 24,
                sentCount: 80,
                failedCount: 20,
                topFailureReasons: [
                    .init(reason: "badDeviceToken", count: 12),
                    .init(reason: "tooManyRequests", count: 5)
                ]
            ),
            sendNoOps: .init(
                windowHours: 24,
                totalAttemptCount: 40,
                noOpAttemptCount: 10,
                reasons: [
                    .init(reason: "zero_candidates", count: 6),
                    .init(reason: "missing_geolocation", count: 4)
                ]
            ),
            zeroCandidateRate: .init(
                windowHours: 24,
                candidateResolutionAttemptCount: 24,
                zeroCandidateAttemptCount: 6
            ),
            targetableCoverage: .init(
                installationFreshnessSeconds: 86_400,
                presenceFreshnessSeconds: 21_600,
                hardStalePresenceThresholdSeconds: 86_400,
                activeSubscribedInstallationCount: 100,
                targetableInstallationCount: 61,
                candidateQueryEligibleInstallationCount: 74,
                hardStalePresenceCount: 13,
                lossBreakdown: .init(
                    missingDeviceTokenCount: 3,
                    staleInstallationHeartbeatCount: 12,
                    stalePresenceCount: 17,
                    missingTargetingDataCount: 7
                )
            ),
            h3Derivation: .init(
                windowHours: 24,
                geometryBearingRevisionCount: 18,
                successfulConversionCount: 15,
                p95ConversionSeconds: 24
            ),
            recentNotificationDebugEntries: [
                .init(
                    createdAt: isoDate("2026-04-10T11:59:00Z"),
                    seriesID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    eventName: "Tornado Warning",
                    recordKind: "candidate",
                    mode: "h3",
                    reason: "new",
                    title: "Tornado Warning",
                    subtitle: "Includes your location",
                    body: "Take shelter now",
                    ledgerStatus: "sent",
                    apnsErrorCode: nil
                ),
                .init(
                    createdAt: isoDate("2026-04-10T11:58:00Z"),
                    seriesID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    eventName: "Flash Flood Warning",
                    recordKind: "preview_no_candidates",
                    mode: "ugc",
                    reason: "update",
                    title: "Flash Flood Warning - Update",
                    subtitle: "Updated for your area",
                    body: "Avoid flooded roads",
                    ledgerStatus: nil,
                    apnsErrorCode: nil
                )
            ],
            touchedSeries: [
                .init(
                    seriesID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                    eventName: "Severe Thunderstorm Warning",
                    state: "active",
                    ugcCodes: ["COC005", "COC013"],
                    tornadoDetection: "OBSERVED",
                    tornadoDamageThreat: "CONSIDERABLE",
                    currentRevisionUrn: "urn:oid:series-1",
                    touchedAt: isoDate("2026-04-10T11:59:30Z"),
                    latestRevisionReceivedAt: isoDate("2026-04-10T11:59:00Z"),
                    seriesUpdatedAt: isoDate("2026-04-10T11:59:30Z")
                ),
                .init(
                    seriesID: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                    eventName: "Red Flag Warning",
                    state: "expired",
                    ugcCodes: [],
                    tornadoDetection: nil,
                    tornadoDamageThreat: nil,
                    currentRevisionUrn: "urn:oid:series-2",
                    touchedAt: isoDate("2026-04-10T11:54:00Z"),
                    latestRevisionReceivedAt: isoDate("2026-04-10T11:53:00Z"),
                    seriesUpdatedAt: isoDate("2026-04-10T11:54:00Z")
                )
            ]
        )
    }

    @Test("snapshot response computes rates and ages")
    func snapshotResponseComputesRatesAndAges() {
        let renderedAt = isoDate("2026-04-10T12:00:00Z")
        let response = OperatorDashboardSnapshotResponse(
            snapshot: makeSnapshot(),
            renderedAt: renderedAt
        )

        #expect(response.redLights.ingestFreshness.timeSinceLastSuccessfulSweepSeconds == 300)
        #expect(response.redLights.pipelineBacklogAge.oldestPendingTargetDispatchAgeSeconds == 360)
        #expect(abs((response.deliveryKPIs.apnsDeliverySuccessRate.successRate ?? 0) - 0.8) < 0.0001)
        #expect(abs((response.deliveryKPIs.sendNoOpRateByReason.noOpRate ?? 0) - 0.25) < 0.0001)
        #expect(abs((response.deliveryKPIs.zeroCandidateRevisionRate.zeroCandidateRate ?? 0) - 0.25) < 0.0001)
        #expect(abs((response.audienceTargeting.freshTargetableInstallationCoverage.targetableRate ?? 0) - 0.61) < 0.0001)
        #expect(abs((response.audienceTargeting.freshTargetableInstallationCoverage.candidateQueryEligibilityRate ?? 0) - 0.74) < 0.0001)
        #expect(abs((response.audienceTargeting.alertsWithGeographyAndH3Success.successRate ?? 0) - 0.8333333333) < 0.0001)
    }

    @Test("legacy stored snapshot decodes without ugcCodes")
    func legacyStoredSnapshotDecodesWithoutUGCCodes() throws {
        let json = #"""
        {
          "schemaVersion": 0,
          "generatedAt": "2026-04-10T12:00:00Z",
          "fastRefreshedAt": "2026-04-10T12:00:00Z",
          "standardRefreshedAt": null,
          "slowRefreshedAt": null,
          "ingestFreshness": {
            "recentAttemptLimit": 60,
            "lastSuccessfulCompletedAt": null,
            "lastAttemptCompletedAt": null,
            "recentSuccessCount": 0,
            "recentFailureCount": 0,
            "lastFailureCompletedAt": null,
            "lastFailureMessage": null
          },
          "pipelineBacklog": {
            "pendingTargetDispatchCount": 0,
            "oldestPendingTargetDispatchCreatedAt": null,
            "pendingNotificationDispatchCount": 0,
            "oldestPendingNotificationDispatchCreatedAt": null
          },
          "stuckClaimedRows": {
            "thresholdSeconds": 300,
            "count": 0,
            "oldestClaimedCreatedAt": null
          },
          "staleActiveSeries": {
            "graceSeconds": 900,
            "count": 0
          },
          "endToEndLatency": {
            "windowHours": 24,
            "successfulRevisionCount": 0,
            "p95Seconds": null
          },
          "apnsDelivery": {
            "windowHours": 24,
            "sentCount": 0,
            "failedCount": 0,
            "topFailureReasons": []
          },
          "sendNoOps": {
            "windowHours": 24,
            "totalAttemptCount": 0,
            "noOpAttemptCount": 0,
            "reasons": []
          },
          "zeroCandidateRate": {
            "windowHours": 24,
            "candidateResolutionAttemptCount": 0,
            "zeroCandidateAttemptCount": 0
          },
          "targetableCoverage": {
            "installationFreshnessSeconds": 86400,
            "presenceFreshnessSeconds": 21600,
            "activeSubscribedInstallationCount": 0,
            "targetableInstallationCount": 0,
            "lossBreakdown": {
              "missingDeviceTokenCount": 0,
              "staleInstallationHeartbeatCount": 0,
              "stalePresenceCount": 0,
              "missingTargetingDataCount": 0
            }
          },
          "h3Derivation": {
            "windowHours": 24,
            "geometryBearingRevisionCount": 0,
            "successfulConversionCount": 0,
            "p95ConversionSeconds": null
          },
          "recentNotificationDebugEntries": [],
          "touchedSeries": [
            {
              "seriesID": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC",
              "eventName": "Severe Thunderstorm Warning",
              "state": "active",
              "currentRevisionUrn": "urn:oid:series-1",
              "touchedAt": "2026-04-10T11:59:30Z",
              "latestRevisionReceivedAt": "2026-04-10T11:59:00Z",
              "seriesUpdatedAt": "2026-04-10T11:59:30Z"
            }
          ]
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(OperatorDashboardStoredSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.schemaVersion == 0)
        #expect(snapshot.touchedSeries.first?.ugcCodes == [])
        #expect(snapshot.targetableCoverage.hardStalePresenceThresholdSeconds == Int(LocationFreshnessPolicy.hardStaleThreshold))
        #expect(snapshot.targetableCoverage.candidateQueryEligibleInstallationCount == 0)
        #expect(snapshot.targetableCoverage.hardStalePresenceCount == 0)
    }

    @Test("legacy snapshot backfills touched-series fields")
    func legacySnapshotBackfillsTouchedSeriesFields() {
        var snapshot = makeSnapshot()
        snapshot.schemaVersion = 1
        snapshot.touchedSeries[0].ugcCodes = []
        snapshot.touchedSeries[0].tornadoDetection = nil
        snapshot.touchedSeries[0].tornadoDamageThreat = nil

        let upgraded = backfillTouchedSeriesFields(
            in: snapshot,
            detailsBySeriesID: [
                UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!: .init(
                    ugcCodes: ["COC005", "COC013"],
                    tornadoDetection: "OBSERVED",
                    tornadoDamageThreat: "CONSIDERABLE"
                )
            ]
        )

        #expect(upgraded.schemaVersion == OperatorDashboardStoredSnapshot.currentSchemaVersion)
        #expect(upgraded.touchedSeries[0].ugcCodes == ["COC005", "COC013"])
        #expect(upgraded.touchedSeries[0].tornadoDetection == "OBSERVED")
        #expect(upgraded.touchedSeries[0].tornadoDamageThreat == "CONSIDERABLE")
    }

    @Test("metrics endpoint returns canonical dashboard snapshot")
    func metricsEndpointReturnsSnapshot() async throws {
        try await withApp { app in
            app.operatorDashboardSnapshotStore = StubSnapshotStore(snapshot: makeSnapshot())

            try await app.testing().test(.GET, "v1/metrics", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let payload = try res.content.decode(OperatorDashboardSnapshotResponse.self)
                #expect(payload.redLights.staleActiveSeriesCount.count == 5)
                #expect(payload.operatorContext.recentNotificationDebugEntries.entries.count == 2)
                #expect(payload.operatorContext.lastTouchedSeries.entries.first?.eventName == "Severe Thunderstorm Warning")
                #expect(payload.operatorContext.lastTouchedSeries.entries.first?.ugcCodes == ["COC005", "COC013"])
                #expect(payload.operatorContext.lastTouchedSeries.entries.first?.tornadoDetection == "OBSERVED")
                #expect(payload.operatorContext.lastTouchedSeries.entries.first?.tornadoDamageThreat == "CONSIDERABLE")
                let coverage = payload.audienceTargeting.freshTargetableInstallationCoverage
                #expect(coverage.hardStalePresenceThresholdSeconds == 86_400)
                #expect(coverage.candidateQueryEligibleInstallationCount == 74)
                #expect(coverage.hardStalePresenceCount == 13)
                #expect(abs((coverage.candidateQueryEligibilityRate ?? 0) - 0.74) < 0.0001)
            })
        }
    }

    @Test("dashboard page renders core sections from snapshot")
    func dashboardPageRendersSnapshot() async throws {
        try await withApp { app in
            app.operatorDashboardSnapshotStore = StubSnapshotStore(snapshot: makeSnapshot())

            try await app.testing().test(.GET, "dashboard", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .html)
                #expect(res.body.string.contains("Red Lights"))
                #expect(res.body.string.contains("Delivery KPIs"))
                #expect(res.body.string.contains("Audience / Targeting"))
                #expect(res.body.string.contains("Operator Context"))
                #expect(res.body.string.contains("Arcus Signal"))
                #expect(res.body.string.contains("Tornado Warning"))
                #expect(res.body.string.contains("Tornado detection"))
                #expect(res.body.string.contains("Tornado damage threat"))
                #expect(res.body.string.contains("ugc_codes"))
                #expect(res.body.string.contains("COC005, COC013"))
                #expect(res.body.string.contains("OBSERVED"))
                #expect(res.body.string.contains("CONSIDERABLE"))
                #expect(res.body.string.contains("urn:oid:series-1"))
                #expect(res.body.string.contains("fetch('/v1/metrics'"))
                #expect(res.body.string.contains("window.setTimeout(fetchSnapshot, nextDelay)"))
                #expect(res.body.string.contains("The page polls the canonical"))
                #expect(res.body.string.components(separatedBy: "Eligible ≤24h").count == 3)
                #expect(res.body.string.contains("Excluded &gt;24h"))
                #expect(res.body.string.contains("Excluded >24h"))
                #expect(res.body.string.contains("74 / 100"))
                #expect(res.body.string.contains(">13<"))
                #expect(res.body.string.contains("candidateQueryEligibilityRate"))
                #expect(res.body.string.contains("candidateQueryEligibleInstallationCount"))
                #expect(res.body.string.contains("hardStalePresenceCount"))
                #expect(res.body.string.contains("hero-rendered-at"))
                #expect(res.body.string.contains("http-equiv=\"refresh\"") == false)
            })
        }
    }

    @Test("dashboard page returns unavailable shell without snapshot")
    func dashboardPageUnavailableWithoutSnapshot() async throws {
        try await withApp { app in
            app.operatorDashboardSnapshotStore = StubSnapshotStore(snapshot: nil)

            try await app.testing().test(.GET, "dashboard", afterResponse: { res async in
                #expect(res.status == .serviceUnavailable)
                #expect(res.body.string.contains("Dashboard Snapshot Unavailable"))
                #expect(res.body.string.contains("window.location.replace('/dashboard')"))
                #expect(res.body.string.contains("http-equiv=\"refresh\"") == false)
            })
        }
    }
}
