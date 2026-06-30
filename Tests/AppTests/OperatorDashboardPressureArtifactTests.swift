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
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
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
    }

    private func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    @Test("fast refresh selects an exact usable pressure artifact and preserves catalog views")
    func fastRefreshSelectsAnExactUsablePressureArtifactAndPreservesCatalogViews() async throws {
        try await withApp { app in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
            let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
            let exactFileURL = makeTempRegularFile(contents: Data("exact".utf8))
            let exactPressureRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 1,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: exactFileURL.path,
                byteSize: 9_999,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 2),
                errorSummary: nil
            )
            try await exactPressureRow.create(on: app.db)

            let newerFailedRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 24),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 24),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .failed,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 45),
                errorSummary: "most recent failure"
            )
            try await newerFailedRow.create(on: app.db)

            let readyLaterRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: makeTempRegularFile(contents: Data("later".utf8)).path,
                byteSize: 5,
                source: .nomads,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21, minute: 2)
            )
            try await readyLaterRow.create(on: app.db)

            let warmingRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21),
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
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
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
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .expired,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: nil
            )
            try await expiredRow.create(on: app.db)

            let failedOlderRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .failed,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 17, minute: 30),
                errorSummary: "older failure"
            )
            try await failedOlderRow.create(on: app.db)

            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: now)

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let artifacts = snapshot.modelArtifacts
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)
            let html = OperatorDashboardPageRenderer.render(snapshot: response)

            #expect(snapshot.schemaVersion == OperatorDashboardStoredSnapshot.currentSchemaVersion)
            #expect(artifacts.pressureArtifactCatalog.totalRowCount == 7)
            #expect(artifacts.pressureArtifactCatalog.pendingCount == 1)
            #expect(artifacts.pressureArtifactCatalog.warmingCount == 1)
            #expect(artifacts.pressureArtifactCatalog.readyCount == 2)
            #expect(artifacts.pressureArtifactCatalog.failedCount == 2)
            #expect(artifacts.pressureArtifactCatalog.expiredCount == 1)
            #expect(artifacts.pressureArtifactReadiness.selectionOutcome == .exact)
            #expect(artifacts.pressureArtifactReadiness.status == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(artifacts.pressureArtifactReadiness.runTime == exactPressureRow.runTime)
            #expect(artifacts.pressureArtifactReadiness.forecastHour == exactPressureRow.forecastHour)
            #expect(artifacts.pressureArtifactReadiness.validTime == exactPressureRow.validTime)
            #expect(artifacts.pressureArtifactReadiness.fieldSetVersion == currentVersion.rawValue)
            #expect(artifacts.pressureArtifactReadiness.byteSize == 5)
            #expect(artifacts.pressureArtifactReadiness.source == PressureArtifactCatalogSource.aws.rawValue)
            #expect(artifacts.pressureArtifactReadiness.updatedAt == exactPressureRow.updatedAt)
            #expect(artifacts.pressureArtifactReadiness.lastCheckedAt == exactPressureRow.lastCheckedAt)
            #expect(artifacts.pressureArtifactReadiness.errorSummary == exactPressureRow.errorSummary)
            #expect(artifacts.pressureArtifactReadiness.readinessReason == nil)
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureAt == failedOlderRow.updatedAt)
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureSummary == "older failure")
            #expect(artifacts.recentPressureArtifacts.entries.count == 5)
            #expect(artifacts.recentPressureArtifacts.entries.map(\.validTime) == [
                newerFailedRow.validTime,
                exactPressureRow.validTime,
                readyLaterRow.validTime,
                warmingRow.validTime,
                pendingRow.validTime
            ])
            #expect(artifacts.recentPressureArtifacts.entries.first?.status == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(artifacts.recentPressureArtifacts.entries.first?.errorSummary == "most recent failure")
            #expect(artifacts.recentPressureArtifacts.entries.contains { $0.byteSize == nil })
            #expect(artifacts.recentPressureArtifacts.entries.contains { $0.lastCheckedAt == nil })
            #expect(artifacts.recentPressureArtifacts.entries.allSatisfy { $0.fieldSetVersion == currentVersion.rawValue })
            #expect(response.modelArtifacts.pressureArtifactReadiness.validTimeAgeSeconds == 0)
            #expect(response.modelArtifacts.pressureArtifactReadiness.selectionOutcome == .exact)
            #expect(response.modelArtifacts.pressureArtifactReadiness.readinessReason == nil)
            #expect(html.contains("EXACT"))
            #expect(html.contains("accent"))
            #expect(html.contains("Catalog status"))
            #expect(html.contains("localPath") == false)
        }
    }

    @Test("empty pressure artifact catalogs produce empty dashboard metrics")
    func emptyPressureArtifactCatalogsProduceEmptyDashboardMetrics() async throws {
        try await withApp { app in
            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18))

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let artifacts = snapshot.modelArtifacts

            #expect(artifacts.pressureArtifactReadiness.selectionOutcome == .unavailable)
            #expect(artifacts.pressureArtifactReadiness.status == nil)
            #expect(artifacts.pressureArtifactReadiness.runTime == nil)
            #expect(artifacts.pressureArtifactReadiness.readinessReason == "No current-version catalog artifact exists.")
            #expect(artifacts.pressureArtifactCatalog.totalRowCount == 0)
            #expect(artifacts.pressureArtifactCatalog.readyCount == 0)
            #expect(artifacts.pressureArtifactCatalog.mostRecentFailureAt == nil)
            #expect(artifacts.recentPressureArtifacts.entries.isEmpty)
        }
    }

    @Test("newer failed rows do not hide an eligible stale pressure artifact")
    func newerFailedRowsDoNotHideAnEligibleStalePressureArtifact() async throws {
        try await withApp { app in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
            let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
            let missingExactPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-exact-\(UUID().uuidString).grib2")
            let missingExactRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: missingExactPath.path,
                byteSize: 111,
                source: .aws
            )
            let staleFileURL = makeTempRegularFile(contents: Data("stale".utf8))
            let staleRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: staleFileURL.path,
                byteSize: 4_096,
                source: .nomads,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 2)
            )
            let newerFailedRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 24),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 24),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .failed,
                localPath: nil,
                byteSize: nil,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 45),
                errorSummary: "most recent failure"
            )

            try await missingExactRow.create(on: app.db)
            try await staleRow.create(on: app.db)
            try await newerFailedRow.create(on: app.db)

            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: now)

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let readiness = snapshot.modelArtifacts.pressureArtifactReadiness
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)
            let html = OperatorDashboardPageRenderer.render(snapshot: response)

            #expect(readiness.selectionOutcome == .stale)
            #expect(readiness.status == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(readiness.readinessReason?.contains("Bounded stale fallback selected") == true)
            #expect(readiness.runTime == staleRow.runTime)
            #expect(readiness.forecastHour == staleRow.forecastHour)
            #expect(readiness.validTime == staleRow.validTime)
            #expect(readiness.byteSize == 5)
            #expect(readiness.source == PressureArtifactCatalogSource.nomads.rawValue)
            #expect(html.contains("STALE"))
            #expect(html.contains("warn"))
        }
    }

    @Test("current-version exact misses do not fall back to older field-set versions")
    func currentVersionExactMissesDoNotFallBackToOlderFieldSetVersions() async throws {
        try await withApp { app in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
            let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
            let oldVersionFileURL = makeTempRegularFile(contents: Data("older-version".utf8))
            let currentMissingPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-current-\(UUID().uuidString).grib2")

            let currentMissingRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: currentMissingPath.path,
                byteSize: 123,
                source: .aws
            )
            let oldVersionRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV1,
                status: .ready,
                localPath: oldVersionFileURL.path,
                byteSize: 13,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 23, minute: 1)
            )

            try await currentMissingRow.create(on: app.db)
            try await oldVersionRow.create(on: app.db)

            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: now)

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let readiness = snapshot.modelArtifacts.pressureArtifactReadiness
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)
            let html = OperatorDashboardPageRenderer.render(snapshot: response)

            #expect(readiness.selectionOutcome == .unavailable)
            #expect(readiness.status == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(readiness.fieldSetVersion == currentVersion.rawValue)
            #expect(readiness.readinessReason?.contains("no usable local artifact file") == true)
            #expect(readiness.byteSize == 123)
            #expect(html.contains("UNAVAILABLE"))
            #expect(html.contains("danger"))
        }
    }

    @Test("pressure artifacts older than the stale window are unavailable")
    func pressureArtifactsOlderThanTheStaleWindowAreUnavailable() async throws {
        try await withApp { app in
            let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 23)
            let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
            let oldFileURL = makeTempRegularFile(contents: Data("too-old".utf8))
            let oldRow = PressureArtifactCatalogModel(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                forecastHour: 0,
                validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20),
                product: .wrfprsf,
                fieldSetVersion: currentVersion,
                status: .ready,
                localPath: oldFileURL.path,
                byteSize: 7,
                source: .aws,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 20, minute: 5)
            )

            try await oldRow.create(on: app.db)

            try await OperatorDashboardSnapshotRefresher().refreshIfDue(on: app, forceAll: true, now: now)

            let snapshot = try #require(try await app.operatorDashboardSnapshotStore.load(on: app.db))
            let readiness = snapshot.modelArtifacts.pressureArtifactReadiness
            let response = OperatorDashboardSnapshotResponse(snapshot: snapshot, renderedAt: now)
            let html = OperatorDashboardPageRenderer.render(snapshot: response)

            #expect(readiness.selectionOutcome == .unavailable)
            #expect(readiness.status == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(readiness.readinessReason?.contains("outside the bounded stale window") == true)
            #expect(readiness.runTime == oldRow.runTime)
            #expect(readiness.byteSize == 7)
            #expect(html.contains("UNAVAILABLE"))
            #expect(html.contains("danger"))
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
        #expect(snapshot.modelArtifacts.pressureArtifactReadiness.selectionOutcome == nil)
        #expect(snapshot.modelArtifacts.pressureArtifactReadiness.status == nil)
        #expect(snapshot.modelArtifacts.pressureArtifactReadiness.readinessReason == nil)
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
                #expect(payload.modelArtifacts.pressureArtifactReadiness.selectionOutcome == snapshot.modelArtifacts.pressureArtifactReadiness.selectionOutcome)
                #expect(payload.modelArtifacts.pressureArtifactReadiness.readinessReason == snapshot.modelArtifacts.pressureArtifactReadiness.readinessReason)
                #expect(payload.modelArtifacts.pressureArtifactCatalog.totalCount == snapshot.modelArtifacts.pressureArtifactCatalog.totalRowCount)
                #expect(payload.modelArtifacts.recentPressureArtifacts.entries.count == 1)
                #expect(body.contains("modelArtifacts"))
                #expect(body.contains("pressureArtifactReadiness"))
                #expect(body.contains("pressureArtifactCatalog"))
                #expect(body.contains("recentPressureArtifacts"))
                #expect(body.contains("selectionOutcome"))
                #expect(body.contains("readinessReason"))
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
                #expect(res.body.string.contains("UNAVAILABLE"))
                #expect(res.body.string.contains("danger"))
                #expect(res.body.string.contains("20 B"))
                #expect(res.body.string.contains("FH 9"))
                #expect(res.body.string.contains("Newest catalog row is failed"))
                #expect(res.body.string.contains("localPath") == false)
                #expect(res.body.string.contains("renderPressureArtifactOutcome"))
                #expect(res.body.string.contains("renderPressureArtifactOutcomeClass"))
                #expect(res.body.string.contains("renderPressureArtifactReadinessCard"))
                #expect(res.body.string.contains("renderPressureArtifactCatalogCard"))
                #expect(res.body.string.contains("renderRecentPressureArtifactsTable"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.pressureArtifactReadiness?.refreshedAt"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.pressureArtifactCatalog?.refreshedAt"))
                #expect(res.body.string.contains("snapshot.modelArtifacts?.recentPressureArtifacts?.refreshedAt"))
            })
        }
    }

    @Test("dashboard renderer covers exact, stale, unavailable, and legacy readiness states")
    func dashboardRendererCoversExactStaleUnavailableAndLegacyReadinessStates() {
        let exactSnapshot = makeSnapshot(readiness: makeExactReadinessMetric())
        let staleSnapshot = makeSnapshot(readiness: makeStaleReadinessMetric())
        let unavailableSnapshot = makeSnapshot(readiness: makeUnavailableReadinessMetric())
        let legacySnapshot = OperatorDashboardStoredSnapshot(
            generatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            fastRefreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            modelArtifacts: .init(
                pressureArtifactReadiness: .init(
                    refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
                    status: nil,
                    runTime: nil,
                    forecastHour: nil,
                    validTime: nil,
                    fieldSetVersion: nil,
                    byteSize: nil,
                    source: nil,
                    updatedAt: nil,
                    lastCheckedAt: nil,
                    errorSummary: nil,
                    readinessReason: nil
                ),
                pressureArtifactCatalog: .init(),
                recentPressureArtifacts: .init()
            )
        )

        let cases: [(snapshot: OperatorDashboardStoredSnapshot, expectedPrimary: String, expectedClass: String?, expectedReason: String?)] = [
            (exactSnapshot, "EXACT", "accent", nil),
            (staleSnapshot, "STALE", "warn", "Bounded stale fallback selected"),
            (unavailableSnapshot, "UNAVAILABLE", "danger", "Newest catalog row is failed"),
            (legacySnapshot, "NO DATA", nil, nil)
        ]

        for testCase in cases {
            let response = OperatorDashboardSnapshotResponse(snapshot: testCase.snapshot, renderedAt: testCase.snapshot.generatedAt)
            let html = OperatorDashboardPageRenderer.render(snapshot: response)

            #expect(response.modelArtifacts.pressureArtifactReadiness.selectionOutcome == testCase.snapshot.modelArtifacts.pressureArtifactReadiness.selectionOutcome)
            #expect(html.contains(testCase.expectedPrimary))
            #expect(html.contains("renderPressureArtifactOutcome"))
            #expect(html.contains("renderPressureArtifactOutcomeClass"))

            if let expectedClass = testCase.expectedClass {
                #expect(html.contains("primary \(expectedClass)"))
            }

            if let expectedReason = testCase.expectedReason {
                #expect(html.contains(expectedReason))
            }
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

    func makeSnapshot(
        readiness: StoredPressureArtifactDashboardReadinessMetric? = nil
    ) -> OperatorDashboardStoredSnapshot {
        let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
        let readiness = readiness ?? makeUnavailableReadinessMetric()
        return .init(
            generatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            fastRefreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            modelArtifacts: .init(
                pressureArtifactReadiness: readiness,
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

    func makeExactReadinessMetric() -> StoredPressureArtifactDashboardReadinessMetric {
        let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
        return .init(
            refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            selectionOutcome: .exact,
            status: PressureArtifactCatalogStatus.ready.rawValue,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: currentVersion.rawValue,
            byteSize: 20,
            source: PressureArtifactCatalogSource.aws.rawValue,
            updatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
            lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 2),
            errorSummary: nil,
            readinessReason: nil
        )
    }

    func makeStaleReadinessMetric() -> StoredPressureArtifactDashboardReadinessMetric {
        let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
        return .init(
            refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            selectionOutcome: .stale,
            status: PressureArtifactCatalogStatus.ready.rawValue,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12),
            forecastHour: 10,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            fieldSetVersion: currentVersion.rawValue,
            byteSize: 4_096,
            source: PressureArtifactCatalogSource.nomads.rawValue,
            updatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
            lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 2),
            errorSummary: nil,
            readinessReason: "Bounded stale fallback selected after all exact candidates missed."
        )
    }

    func makeUnavailableReadinessMetric() -> StoredPressureArtifactDashboardReadinessMetric {
        let currentVersion = HrrrProduct.wrfprsf.defaultFieldSetVersion
        return .init(
            refreshedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18),
            selectionOutcome: .unavailable,
            status: PressureArtifactCatalogStatus.failed.rawValue,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            fieldSetVersion: currentVersion.rawValue,
            byteSize: 20,
            source: PressureArtifactCatalogSource.aws.rawValue,
            updatedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 1),
            lastCheckedAt: nil,
            errorSummary: "validation failed",
            readinessReason: "Newest catalog row is failed: validation failed."
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

    func makeTempRegularFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-artifact-\(UUID().uuidString).grib2")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }
}
