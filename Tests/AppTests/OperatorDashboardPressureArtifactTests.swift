@testable import App
import Fluent
import FluentSQL
import Foundation
import Testing
import Vapor
import VaporTesting

@Suite("Operator dashboard pressure artifacts", .serialized)
struct OperatorDashboardPressureArtifactTests {
    private func withApp(test: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try await configure(app, mode: .api)
            try await app.autoMigrate()
            try await clearCatalog(on: app.db)
            try await test(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    @Test("fast refresh surfaces current-version pressure artifact catalog metrics")
    func fastRefreshSurfacesCurrentVersionPressureArtifactCatalogMetrics() async throws {
        try await withApp { app in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
            let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion

            let obsoleteFutureRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV1,
                status: .ready,
                localPath: "/tmp/obsolete.grib2",
                byteSize: 99,
                source: .aws
            )
            try await obsoleteFutureRow.create(on: app.db)

            let readyLatestRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 16),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .failed,
                localPath: "/tmp/latest-failed.grib2",
                byteSize: 20,
                source: .aws,
                lastCheckedAt: nil,
                errorSummary: "pressure artifact validation failed"
            )
            try await readyLatestRow.create(on: app.db)

            let readyLaterRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 15),
                forecastHour: 1,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: "/tmp/ready.grib2",
                byteSize: 2_048,
                source: .nomads,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21, minute: 2)
            )
            try await readyLaterRow.create(on: app.db)

            let warmingRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14),
                forecastHour: 2,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .warming,
                localPath: nil,
                byteSize: nil,
                source: .unknown,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20, minute: 30)
            )
            try await warmingRow.create(on: app.db)

            let pendingRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                forecastHour: 3,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .pending,
                localPath: nil,
                byteSize: nil,
                source: .unknown,
                lastCheckedAt: nil
            )
            try await pendingRow.create(on: app.db)

            let expiredRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12),
                forecastHour: 4,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .expired,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: nil
            )
            try await expiredRow.create(on: app.db)

            let failedLaterRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 11),
                forecastHour: 5,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 17),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .failed,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 17, minute: 30),
                errorSummary: "most recent failure"
            )
            try await failedLaterRow.create(on: app.db)

            let readyOmittedRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 10),
                forecastHour: 6,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 16),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: "/tmp/omitted.grib2",
                byteSize: 4_096,
                source: .aws
            )
            try await readyOmittedRow.create(on: app.db)

            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: now)

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let artifacts = snapshot.modelArtifacts
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)

            #expect(snapshot.schemaVersion == OperatorDashboardStoredSnapshot.currentSchemaVersion)
            #expect(artifacts.pressureArtifactCatalog.totalRowCount == 7)
            #expect(artifacts.pressureArtifactCatalog.pendingCount == 1)
            #expect(artifacts.pressureArtifactCatalog.warmingCount == 1)
            #expect(artifacts.pressureArtifactCatalog.readyCount == 2)
            #expect(artifacts.pressureArtifactCatalog.failedCount == 2)
            #expect(artifacts.pressureArtifactCatalog.expiredCount == 1)
            #expect(artifacts.pressureArtifactReadiness.status == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(artifacts.pressureArtifactReadiness.runTime == readyLatestRow.runTime)
            #expect(artifacts.pressureArtifactReadiness.forecastHour == readyLatestRow.forecastHour)
            #expect(artifacts.pressureArtifactReadiness.validTime == readyLatestRow.validTime)
            #expect(artifacts.pressureArtifactReadiness.fieldSetVersion == currentVersion.rawValue)
            #expect(artifacts.pressureArtifactReadiness.byteSize == 20)
            #expect(artifacts.pressureArtifactReadiness.source == PressureArtifactCatalogSource.aws.rawValue)
            #expect(artifacts.pressureArtifactReadiness.updatedAt == readyLatestRow.updatedAt)
            #expect(artifacts.pressureArtifactReadiness.lastCheckedAt == nil)
            #expect(artifacts.pressureArtifactReadiness.errorSummary == "pressure artifact validation failed")
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureAt == failedLaterRow.updatedAt)
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureSummary == "most recent failure")
            #expect(artifacts.recentPressureArtifacts.entries.count == 5)
            #expect(artifacts.recentPressureArtifacts.entries.map(\.validTime) == [
                readyLatestRow.validTime,
                readyLaterRow.validTime,
                warmingRow.validTime,
                pendingRow.validTime,
                expiredRow.validTime
            ])
            #expect(artifacts.recentPressureArtifacts.entries.first?.status == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(artifacts.recentPressureArtifacts.entries.first?.errorSummary == "pressure artifact validation failed")
            #expect(artifacts.recentPressureArtifacts.entries.contains { $0.byteSize == nil })
            #expect(artifacts.recentPressureArtifacts.entries.contains { $0.lastCheckedAt == nil })
            #expect(artifacts.recentPressureArtifacts.entries.allSatisfy { $0.fieldSetVersion == currentVersion.rawValue })
            #expect(response.modelArtifacts.pressureArtifactReadiness.validTimeAgeSeconds == 3_600)
        }
    }

    @Test("empty pressure artifact catalogs produce empty dashboard metrics")
    func emptyPressureArtifactCatalogsProduceEmptyDashboardMetrics() async throws {
        try await withApp { app in
            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18))

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let artifacts = snapshot.modelArtifacts

            #expect(artifacts.pressureArtifactReadiness.status == nil)
            #expect(artifacts.pressureArtifactReadiness.runTime == nil)
            #expect(artifacts.pressureArtifactCatalog.totalRowCount == 0)
            #expect(artifacts.pressureArtifactCatalog.readyCount == 0)
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureAt == nil)
            #expect(artifacts.recentPressureArtifacts.entries.isEmpty)
        }
    }

    @Test("legacy stored snapshots decode with an empty pressure artifact metric")
    func legacyStoredSnapshotsDecodeWithAnEmptyPressureArtifactMetric() throws {
        let json = #"""
        {
          "schemaVersion": 2,
          "generatedAt": "2026-06-03T18:00:00Z",
          "fastRefreshedAt": "2026-06-03T18:00:00Z",
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
          "touchedSeries": []
        }
        """#

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snapshot = try decoder.decode(OperatorDashboardStoredSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.modelArtifacts.pressureArtifactCatalog.totalRowCount == 0)
        #expect(snapshot.modelArtifacts.recentPressureArtifacts.entries.isEmpty)
        #expect(snapshot.modelArtifacts.pressureArtifactReadiness.status == nil)
    }

    @Test("/v1/metrics exposes the model artifacts section")
    func metricsEndpointExposesTheModelArtifactsSection() async throws {
        try await withApp { app in
            let snapshot = makeSnapshot()
            app.operatorDashboardSnapshotStore = StubSnapshotStore(snapshot: snapshot)

            try await app.testing().test(.GET, "v1/metrics", afterResponse: { res async throws in
                #expect(res.status == .ok)

                let body = res.body.string
                let payload = try res.content.decode(OperatorDashboardSnapshotResponse.self)

                #expect(payload.modelArtifacts.pressureArtifactReadiness.status == snapshot.modelArtifacts.pressureArtifactReadiness.status)
                #expect(payload.modelArtifacts.pressureArtifactCatalog.totalCount == snapshot.modelArtifacts.pressureArtifactCatalog.totalRowCount)
                #expect(payload.modelArtifacts.recentPressureArtifacts.entries.count == 1)
                #expect(body.contains("modelArtifacts"))
                #expect(body.contains("pressureArtifactReadiness"))
                #expect(body.contains("pressureArtifactCatalog"))
                #expect(body.contains("recentPressureArtifacts"))
                #expect(body.contains("localPath") == false)
            })
        }
    }

    @Test("dashboard page renders model artifacts tiles and recent table")
    func dashboardPageRendersModelArtifactsTilesAndRecentTable() async throws {
        try await withApp { app in
            app.operatorDashboardSnapshotStore = StubSnapshotStore(snapshot: makeSnapshot())

            try await app.testing().test(.GET, "dashboard", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .html)
                #expect(res.body.string.contains("Model Artifacts"))
                #expect(res.body.string.contains("Pressure artifact readiness"))
                #expect(res.body.string.contains("Pressure artifact catalog"))
                #expect(res.body.string.contains("Recent pressure artifacts"))
                #expect(res.body.string.contains("FAILED"))
                #expect(res.body.string.contains("20 B"))
                #expect(res.body.string.contains("FH 9"))
                #expect(res.body.string.contains("validation failed"))
                #expect(res.body.string.contains("localPath") == false)
                #expect(res.body.string.contains("renderPressureArtifactReadinessCard"))
                #expect(res.body.string.contains("renderPressureArtifactCatalogCard"))
                #expect(res.body.string.contains("renderRecentPressureArtifactsTable"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.pressureArtifactReadiness?.refreshedAt"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.pressureArtifactCatalog?.refreshedAt"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.recentPressureArtifacts?.refreshedAt"))
            })
        }
    }
}

private extension OperatorDashboardPressureArtifactTests {
    struct StubSnapshotStore: OperatorDashboardSnapshotStore {
        let snapshot: OperatorDashboardStoredSnapshot?

        func load(on database: any Database) async throws -> OperatorDashboardStoredSnapshot? {
            snapshot
        }

        func save(_ snapshot: OperatorDashboardStoredSnapshot, on database: any Database) async throws {
            _ = snapshot
        }
    }

    func makeSnapshot() -> OperatorDashboardStoredSnapshot {
        let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
        return .init(
            generatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            fastRefreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            modelArtifacts: .init(
                pressureArtifactReadiness: .init(
                    refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                    status: PressureArtifactCatalogStatus.failed.rawValue,
                    runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                    forecastHour: 9,
                    validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                    fieldSetVersion: currentVersion.rawValue,
                    byteSize: 20,
                    source: PressureArtifactCatalogSource.aws.rawValue,
                    updatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
                    lastCheckedAt: nil,
                    errorSummary: "validation failed"
                ),
                pressureArtifactCatalog: .init(
                    refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                    totalRowCount: 1,
                    pendingCount: 0,
                    warmingCount: 0,
                    readyCount: 0,
                    failedCount: 1,
                    expiredCount: 0,
                    mostRecentFailureAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
                    mostRecentFailureSummary: "validation failed"
                ),
                recentPressureArtifacts: .init(
                    refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                    entries: [
                        .init(
                            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                            forecastHour: 9,
                            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                            product: HrrrProduct.wrfprsf.rawValue,
                            fieldSetVersion: currentVersion.rawValue,
                            status: PressureArtifactCatalogStatus.failed.rawValue,
                            byteSize: 20,
                            source: PressureArtifactCatalogSource.aws.rawValue,
                            createdAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                            updatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
                            lastCheckedAt: nil,
                            errorSummary: "validation failed"
                        )
                    ]
                )
            )
        )
    }

    func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return components.date!
    }
}
