@testable import App
import Fluent
import FluentSQL
import Foundation
import Logging
import Queues
import Testing
import Vapor

@Suite("Pressure artifact diagnostics", .serialized)
struct PressureArtifactDiagnosticsTests {
    @Test("probe logs idx availability, queue metadata, and enqueue details")
    func probeLogsIdxAvailabilityQueueMetadataAndEnqueueDetails() async throws {
        try await withApp { app, blockingWorkExecutor in
            let surfaceCandidate = makeSurfaceCandidate(runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14), forecastHour: 8)
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let idxURL = HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
            let dispatcher = ProbeWarmJobDispatcherRecorder()
            let loggerContext = makeCapturingLogger(label: "probe")
            let service = HRRRPressureArtifactProbeService(
                runResolver: FixedHrrrRunResolving(
                    resolution: HrrrRunResolution(
                        targetValidTime: surfaceCandidate.validTime,
                        candidates: [surfaceCandidate]
                    )
                ),
                remoteObjectChecker: remoteChecker,
                warmJobDispatcher: dispatcher,
                blockingWorkExecutor: blockingWorkExecutor
            )

            try await seedCatalogRow(status: .failed, payload: payload, on: app.db)
            try await service.probe(on: app, logger: loggerContext.logger)

            let warmEnqueue = try #require(try loggerContext.event(matching: "HRRR pressure artifact warm enqueued."))
            let availability = try #require(try loggerContext.event(matching: "HRRR pressure artifact idx availability checked."))

            #expect(dispatcher.dispatches.count == 1)
            #expect(metadataString(availability.metadata, "idxAvailable") == "true")
            #expect(metadataString(availability.metadata, "idxStatus") == "200")
            #expect(metadataString(availability.metadata, "idxURL") == idxURL.absoluteString)
            #expect(metadataString(availability.metadata, "runTime") == pressureCandidate.runTime.ISO8601Format())
            #expect(metadataString(availability.metadata, "forecastHour") == String(pressureCandidate.forecastHour))
            #expect(metadataString(availability.metadata, "validTime") == pressureCandidate.validTime.ISO8601Format())
            #expect(metadataString(availability.metadata, "product") == pressureCandidate.product.rawValue)
            #expect(metadataString(availability.metadata, "fieldSetVersion") == pressureCandidate.fieldSetVersion.rawValue)
            #expect(metadataString(warmEnqueue.metadata, "queue") == ArcusQueueLane.modelArtifacts.queueName.string)
            #expect(metadataString(warmEnqueue.metadata, "status") == PressureArtifactCatalogStatus.pending.rawValue)
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("probe logs the existing catalog state when warm enqueue is skipped")
    func probeLogsExistingCatalogStateWhenWarmEnqueueIsSkipped() async throws {
        try await withApp { app, blockingWorkExecutor in
            let surfaceCandidate = makeSurfaceCandidate(runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 15), forecastHour: 7)
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let idxURL = HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
            let dispatcher = ProbeWarmJobDispatcherRecorder()
            let loggerContext = makeCapturingLogger(label: "probe-skip")
            let service = HRRRPressureArtifactProbeService(
                runResolver: FixedHrrrRunResolving(
                    resolution: HrrrRunResolution(
                        targetValidTime: surfaceCandidate.validTime,
                        candidates: [surfaceCandidate]
                    )
                ),
                remoteObjectChecker: remoteChecker,
                warmJobDispatcher: dispatcher,
                blockingWorkExecutor: blockingWorkExecutor
            )

            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)
            try await service.probe(on: app, logger: loggerContext.logger)

            let skipped = try #require(try loggerContext.event(matching: "HRRR pressure artifact warm skipped for existing catalog state."))

            #expect(dispatcher.dispatches.isEmpty)
            #expect(metadataString(skipped.metadata, "catalogSkipReason") == "pending row without recovery eligibility")
            #expect(metadataString(skipped.metadata, "status") == PressureArtifactCatalogStatus.pending.rawValue)
            #expect(metadataString(skipped.metadata, "queue") == nil)
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("probe logs exhaustion when every candidate is unavailable")
    func probeLogsExhaustionWhenEveryCandidateIsUnavailable() async throws {
        try await withApp { app, blockingWorkExecutor in
            let firstSurface = makeSurfaceCandidate(runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 15), forecastHour: 7)
            let secondSurface = makeSurfaceCandidate(runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14), forecastHour: 8)
            let firstPressure = makePressureCandidate(from: firstSurface)
            let secondPressure = makePressureCandidate(from: secondSurface)
            let firstIdxURL = HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: firstPressure)
            let secondIdxURL = HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: secondPressure)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(
                availableURLs: [
                    firstIdxURL.absoluteString: false,
                    secondIdxURL.absoluteString: false
                ]
            )
            let loggerContext = makeCapturingLogger(label: "probe-exhaustion")
            let service = HRRRPressureArtifactProbeService(
                runResolver: FixedHrrrRunResolving(
                    resolution: HrrrRunResolution(
                        targetValidTime: firstSurface.validTime,
                        candidates: [firstSurface, secondSurface]
                    )
                ),
                remoteObjectChecker: remoteChecker,
                warmJobDispatcher: ProbeWarmJobDispatcherRecorder(),
                blockingWorkExecutor: blockingWorkExecutor
            )

            try await service.probe(on: app, logger: loggerContext.logger)

            let exhaustion = try #require(try loggerContext.event(matching: "HRRR pressure artifact probe finished without an available candidate."))
            #expect(metadataString(exhaustion.metadata, "targetValidTime") == firstSurface.validTime.ISO8601Format())
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("warm diagnostics include source URLs, selection counts, and validation outcome")
    func warmDiagnosticsIncludeSourceUrlsSelectionCountsAndValidationOutcome() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makeWarmPayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let loggerContext = makeCapturingLogger(label: "warm-success")
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )

            try await service.warm(payload: payload, on: app, logger: loggerContext.logger)

            let claimed = try #require(try loggerContext.event(matching: "Pressure artifact catalog row claimed for warming."))
            let selection = try #require(try loggerContext.event(matching: "Selected HRRR pressure messages for warming."))
            let rangeSelection = try #require(try loggerContext.event(matching: "Selected HRRR pressure byte ranges for warming."))
            let prepared = try #require(try loggerContext.event(matching: "Pressure subset cache prepared for warming."))
            let validation = try #require(try loggerContext.event(matching: "Pressure artifact validation passed."))
            let ready = try #require(try loggerContext.event(matching: "Pressure artifact catalog row transitioned to ready."))

            #expect(metadataString(claimed.metadata, "status") == PressureArtifactCatalogStatus.warming.rawValue)
            #expect(metadataString(selection.metadata, "requestedLevelCount") == String(StormSetupPressureLevel.preferredDescending.count))
            #expect(metadataString(selection.metadata, "selectedPressureLevelCount") == String(StormSetupPressureLevel.preferredDescending.count))
            #expect(metadataString(selection.metadata, "selectedMessageCount") == String(makeExpectedValidationLineCount()))
            #expect(metadataString(selection.metadata, "missingLevelCount") == "0")
            #expect(metadataString(rangeSelection.metadata, "selectedRangeCount") == String(makeExpectedValidationLineCount()))
            #expect(metadataString(prepared.metadata, "sourceURL")?.contains(".wrfprsf") == true)
            #expect(metadataString(prepared.metadata, "idxURL")?.contains(".wrfprsf") == true)
            #expect(metadataString(prepared.metadata, "cacheHit") == "false")
            #expect(metadataString(prepared.metadata, "artifactByteSize") == String(makeExpectedValidationLineCount() * 4))
            #expect(metadataString(prepared.metadata, "maximumByteCount") == "1024")
            #expect((metadataString(prepared.metadata, "downloadDurationMs").flatMap(Int.init) ?? -1) >= 0)
            #expect(metadataString(validation.metadata, "status") == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(metadataString(validation.metadata, "validatedLines") == String(makeExpectedValidationLineCount()))
            #expect(metadataString(ready.metadata, "status") == PressureArtifactCatalogStatus.ready.rawValue)
            #expect(metadataString(ready.metadata, "product") == HrrrProduct.wrfprsf.rawValue)
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("warm validation failure logs a failed transition")
    func warmValidationFailureLogsFailedTransition() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makeWarmPayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(
                error: PressureArtifactWarmValidatorStubError.failedValidation,
                lineCount: makeExpectedValidationLineCount()
            )
            let loggerContext = makeCapturingLogger(label: "warm-failure")
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024
            )

            await #expect(throws: PressureArtifactWarmValidatorStubError.self) {
                try await service.warm(payload: payload, on: app, logger: loggerContext.logger)
            }

            let validationFailed = try #require(try loggerContext.event(matching: "Pressure artifact validation failed."))
            let warmingFailed = try #require(try loggerContext.event(matching: "Pressure artifact warming failed."))
            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(metadataString(validationFailed.metadata, "status") == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(metadataString(warmingFailed.metadata, "status") == PressureArtifactCatalogStatus.failed.rawValue)
            #expect(row.status == .failed)
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("lookup diagnostics distinguish exact hits, miss reasons, and stale selection")
    func lookupDiagnosticsDistinguishExactHitsMissReasonsAndStaleSelection() async throws {
        try await withApp { app, blockingWorkExecutor in
            let loggerContext = makeCapturingLogger(label: "lookup")
            let service = DefaultPressureArtifactCatalogLookupService(
                database: app.db,
                blockingWorkExecutor: blockingWorkExecutor,
                logger: loggerContext.logger
            )

            let exactRunTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            let exactValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let exactCandidate = makePressureCandidate(runTime: exactRunTime, forecastHour: 9)
            let exactArtifactFile = makeTempRegularFile(contents: Data("exact-artifact".utf8))
            try await PressureArtifactCatalogModel(
                runTime: exactRunTime,
                forecastHour: 9,
                validTime: exactValidTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: exactArtifactFile.path,
                byteSize: 14,
                source: .aws
            ).create(on: app.db)

            #expect(try await service.readyArtifact(for: exactCandidate) != nil)
            #expect(try await service.readyArtifact(for: makePressureCandidate(runTime: exactRunTime, forecastHour: 10)) == nil)

            try await PressureArtifactCatalogModel(
                runTime: exactRunTime,
                forecastHour: 11,
                validTime: exactValidTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .pending,
                localPath: exactArtifactFile.path,
                byteSize: 14,
                source: .aws
            ).create(on: app.db)
            #expect(try await service.readyArtifact(for: makePressureCandidate(runTime: exactRunTime, forecastHour: 11)) == nil)

            let unusablePath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-ready-\(UUID().uuidString).grib2")
            try await PressureArtifactCatalogModel(
                runTime: exactRunTime,
                forecastHour: 12,
                validTime: exactValidTime,
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: unusablePath.path,
                byteSize: 14,
                source: .aws
            ).create(on: app.db)
            #expect(try await service.readyArtifact(for: makePressureCandidate(runTime: exactRunTime, forecastHour: 12)) == nil)

            let targetValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22)
            let staleGoodPath = makeTempRegularFile(contents: Data("stale-good".utf8))
            let staleBadPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("missing-stale-\(UUID().uuidString).grib2")
            try await PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-5_400),
                forecastHour: 3,
                validTime: targetValidTime.addingTimeInterval(-1_800),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: staleBadPath.path,
                byteSize: 9,
                source: .aws
            ).create(on: app.db)
            try await PressureArtifactCatalogModel(
                runTime: targetValidTime.addingTimeInterval(-3_600),
                forecastHour: 6,
                validTime: targetValidTime.addingTimeInterval(-3_600),
                product: .wrfprsf,
                fieldSetVersion: .tornadoPressureV2,
                status: .ready,
                localPath: staleGoodPath.path,
                byteSize: 10,
                source: .aws
            ).create(on: app.db)

            let staleArtifact = try #require(try await service.staleArtifact(
                for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [makePressureCandidate(runTime: targetValidTime, forecastHour: 0)])
            ))

            #expect(staleArtifact.freshness == .stale(ageSeconds: 3_600))

            try await clearCatalog(on: app.db)
            let staleMiss = try await service.staleArtifact(
                for: HrrrRunResolution(targetValidTime: targetValidTime, candidates: [makePressureCandidate(runTime: targetValidTime, forecastHour: 0)])
            )

            #expect(staleMiss == nil)

            let exactHit = try #require(try loggerContext.event(matching: "Pressure artifact exact lookup hit."))
            let exactMissing = try #require(try loggerContext.event(matching: "Pressure artifact exact lookup missed."))
            let nonReady = try #require(try loggerContext.event(matching: "Pressure artifact exact lookup skipped non-ready row."))
            let unusableExact = try #require(try loggerContext.event(matching: "Pressure artifact exact lookup found unusable local file."))
            let staleSkip = try #require(try loggerContext.event(matching: "Pressure artifact stale candidate skipped because its file is unusable."))
            let staleHit = try #require(try loggerContext.event(matching: "Pressure artifact stale lookup hit."))
            let staleMissEvent = try #require(try loggerContext.event(matching: "Pressure artifact stale lookup missed."))

            #expect(metadataString(exactHit.metadata, "freshnessOutcome") == "exact")
            #expect(metadataString(exactHit.metadata, "byteSize") == "14")
            #expect(metadataString(exactMissing.metadata, "catalogSkipReason") == "catalogRowMissing")
            #expect(metadataString(nonReady.metadata, "catalogSkipReason") == "catalogStatusNotReady")
            #expect(metadataString(nonReady.metadata, "status") == PressureArtifactCatalogStatus.pending.rawValue)
            #expect(metadataString(unusableExact.metadata, "catalogSkipReason") == "localFileUnusable")
            #expect(metadataString(staleSkip.metadata, "catalogSkipReason") == "localFileUnusable")
            #expect(metadataString(staleHit.metadata, "freshnessOutcome") == "stale")
            #expect(metadataString(staleHit.metadata, "staleAgeSeconds") == "3600")
            #expect(metadataString(staleMissEvent.metadata, "catalogSkipReason") == "noEligibleStaleArtifact")
            assertNoSensitiveMetadata(in: loggerContext.events)
        }
    }

    @Test("request-path diagnostics summarize exact, stale, degraded, and unavailable evidence")
    func requestPathDiagnosticsSummarizeExactStaleDegradedAndUnavailableEvidence() async throws {
        let resolvedH3: Int64 = 617_700_169_958_293_503
        let exactSurfaceValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 15)
        let exactPressureValidTime = exactSurfaceValidTime
        let staleSurfaceValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 15)
        let stalePressureValidTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 15)

        let exactLogger = makeCapturingLogger(label: "request-path-exact")
        let exactSnapshot = makeSnapshot(
            h3Cell: resolvedH3,
            source: makeSurfaceSource(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15),
                forecastHour: 4,
                validTime: exactSurfaceValidTime
            ),
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
            assessment: makeAssessment(),
            freshness: makeFreshness(
                sourceValidTime: exactSurfaceValidTime,
                fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
                sourceRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15),
                forecastHour: 4
            )
        )

        let exactProvider = DefaultStormSetupProvider(
            dateProvider: FixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: exactSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StaticAnvilProfileAnalysisProvider(
                response: makeAnalysisResponse(
                    requestValidTime: exactPressureValidTime,
                    debugRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 15),
                    debugForecastHour: 3,
                    debugValidTime: exactPressureValidTime,
                    effectiveLayerStatus: "notFound",
                    stormMotionStatus: "computed",
                    warnings: []
                )
            ),
            logger: exactLogger.logger
        )

        _ = try await exactProvider.currentSnapshot(for: resolvedH3)
        let exactEvent = try #require(try exactLogger.event(matching: "Storm Setup Anvil evidence resolved."))
        #expect(metadataString(exactEvent.metadata, "artifactOutcome") == "exact")
        #expect(metadataString(exactEvent.metadata, "evidenceStatus") == "degraded")
        #expect(metadataString(exactEvent.metadata, "selectedSurfaceValidTime") == exactSurfaceValidTime.ISO8601Format())
        #expect(metadataString(exactEvent.metadata, "pressureArtifactValidTime") == exactPressureValidTime.ISO8601Format())
        #expect(metadataString(exactEvent.metadata, "pressureArtifactRunTime") == makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 15).ISO8601Format())
        #expect(metadataString(exactEvent.metadata, "pressureArtifactForecastHour") == "3")
        #expect(metadataString(exactEvent.metadata, "pressureArtifactProduct") == HrrrProduct.wrfprsf.rawValue)
        #expect(metadataString(exactEvent.metadata, "staleAgeSeconds") == nil)
        #expect(metadataString(exactEvent.metadata, "reason") == "effective layer not found")

        let staleLogger = makeCapturingLogger(label: "request-path-stale")
        let staleSnapshot = makeSnapshot(
            h3Cell: resolvedH3,
            source: makeSurfaceSource(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21, minute: 15),
                forecastHour: 1,
                validTime: staleSurfaceValidTime
            ),
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
            assessment: makeAssessment(),
            freshness: makeFreshness(
                sourceValidTime: staleSurfaceValidTime,
                fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
                sourceRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21, minute: 15),
                forecastHour: 1
            )
        )
        let staleProvider = DefaultStormSetupProvider(
            dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: staleSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StaticAnvilProfileAnalysisProvider(
                response: makeAnalysisResponse(
                    requestValidTime: stalePressureValidTime,
                    debugRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15),
                    debugForecastHour: 4,
                    debugValidTime: stalePressureValidTime,
                    effectiveLayerStatus: "found",
                    stormMotionStatus: "computed",
                    warnings: [
                        "Pressure artifact stale fallback selected: 10800s older than target valid time 2026-06-03T22:15:00Z."
                    ]
                )
            ),
            logger: staleLogger.logger
        )

        _ = try await staleProvider.currentSnapshot(for: resolvedH3)
        let staleEvent = try #require(try staleLogger.event(matching: "Storm Setup Anvil evidence resolved."))
        #expect(metadataString(staleEvent.metadata, "artifactOutcome") == "stale")
        #expect(metadataString(staleEvent.metadata, "evidenceStatus") == "degraded")
        #expect(metadataString(staleEvent.metadata, "selectedSurfaceValidTime") == staleSurfaceValidTime.ISO8601Format())
        #expect(metadataString(staleEvent.metadata, "pressureArtifactValidTime") == stalePressureValidTime.ISO8601Format())
        #expect(metadataString(staleEvent.metadata, "pressureArtifactRunTime") == makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15).ISO8601Format())
        #expect(metadataString(staleEvent.metadata, "pressureArtifactForecastHour") == "4")
        #expect(metadataString(staleEvent.metadata, "pressureArtifactProduct") == HrrrProduct.wrfprsf.rawValue)
        #expect(metadataString(staleEvent.metadata, "staleAgeSeconds") == "10800")
        #expect(metadataString(staleEvent.metadata, "reason") == "Pressure artifact stale fallback selected: 10800s older than target valid time 2026-06-03T22:15:00Z.")

        let unavailableLogger = makeCapturingLogger(label: "request-path-unavailable")
        let unavailableSnapshot = makeSnapshot(
            h3Cell: resolvedH3,
            source: makeSurfaceSource(
                runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15),
                forecastHour: 4,
                validTime: exactSurfaceValidTime
            ),
            fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
            assessment: makeAssessment(),
            freshness: makeFreshness(
                sourceValidTime: exactSurfaceValidTime,
                fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30),
                sourceRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 18, minute: 15),
                forecastHour: 4
            )
        )
        let unavailableProvider = DefaultStormSetupProvider(
            dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: unavailableSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: ThrowingAnvilProfileAnalysisProvider(error: AnvilProfileAnalysisError.upstreamUnavailable(reason: "Anvil offline")),
            logger: unavailableLogger.logger
        )

        _ = try await unavailableProvider.currentSnapshot(for: resolvedH3)
        let unavailableEvent = try #require(try unavailableLogger.event(matching: "Storm Setup Anvil evidence resolved."))
        #expect(metadataString(unavailableEvent.metadata, "artifactOutcome") == "unavailable")
        #expect(metadataString(unavailableEvent.metadata, "evidenceStatus") == "unavailable")
        #expect(metadataString(unavailableEvent.metadata, "reason")?.contains("Anvil offline") == true)

        let mismatchLogger = makeCapturingLogger(label: "request-path-mismatch")
        let mismatchProvider = DefaultStormSetupProvider(
            dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: exactSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: StaticAnvilProfileAnalysisProvider(
                response: makeAnalysisResponse(
                    requestValidTime: exactPressureValidTime,
                    debugRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 15),
                    debugForecastHour: 3,
                    debugValidTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 21, minute: 15),
                    effectiveLayerStatus: "found",
                    stormMotionStatus: "computed",
                    warnings: []
                )
            ),
            logger: mismatchLogger.logger
        )

        _ = try await mismatchProvider.currentSnapshot(for: resolvedH3)
        let mismatchEvent = try #require(try mismatchLogger.event(matching: "Storm Setup Anvil evidence resolved."))
        #expect(metadataString(mismatchEvent.metadata, "artifactOutcome") == "unavailable")
        #expect(metadataString(mismatchEvent.metadata, "pressureArtifactValidTime") == "nil")
        #expect(metadataString(mismatchEvent.metadata, "reason")?.contains("did not match debug valid time") == true)

        let missingProviderLogger = makeCapturingLogger(label: "request-path-missing-provider")
        let missingProvider = DefaultStormSetupProvider(
            dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: exactSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: nil,
            logger: missingProviderLogger.logger
        )

        _ = try await missingProvider.currentSnapshot(for: resolvedH3)
        let missingProviderEvent = try #require(try missingProviderLogger.event(matching: "Storm Setup Anvil evidence resolved."))
        #expect(metadataString(missingProviderEvent.metadata, "artifactOutcome") == "unavailable")
        #expect(metadataString(missingProviderEvent.metadata, "pressureArtifactValidTime") == "nil")
        #expect(metadataString(missingProviderEvent.metadata, "staleAgeSeconds") == nil)
        #expect(metadataString(missingProviderEvent.metadata, "reason") == "Anvil analysis provider is not configured.")

        let cancellationLogger = makeCapturingLogger(label: "request-path-cancelled")
        let cancellationProvider = DefaultStormSetupProvider(
            dateProvider: makeFixedStormSetupDateProvider(nowDate: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 30)),
            snapshotCache: StubStormSetupSnapshotCache(snapshot: exactSnapshot),
            subsetLoader: UnusedStormSetupSubsetLoader(),
            fieldSampler: UnusedStormSetupFieldSampler(),
            normalizer: StubStormSetupNormalizer(result: makeNormalizationResult(raw: makeRaw())),
            interpreter: TornadoIngredientInterpreter(),
            anvilProfileAnalysisProvider: SuspendedAnvilProfileAnalysisProvider(
                response: makeAnalysisResponse(
                    requestValidTime: exactPressureValidTime,
                    debugRunTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 19, minute: 15),
                    debugForecastHour: 3,
                    debugValidTime: exactPressureValidTime,
                    effectiveLayerStatus: "found",
                    stormMotionStatus: "computed",
                    warnings: []
                )
            ),
            logger: cancellationLogger.logger
        )

        let cancellationTask = Task {
            try await cancellationProvider.currentSnapshot(for: resolvedH3)
        }
        try await Task.sleep(for: .milliseconds(50))
        cancellationTask.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancellationTask.value
        }
        #expect(try cancellationLogger.event(matching: "Storm Setup Anvil evidence resolved.") == nil)
        assertNoRequestPathSensitiveMetadata(in: [exactEvent, staleEvent, unavailableEvent, mismatchEvent, missingProviderEvent])
        assertNoSensitiveMetadata(in: [exactEvent, staleEvent, unavailableEvent, mismatchEvent, missingProviderEvent])
    }

    @Test("preview diagnostics include surface pressure and surface cache state")
    func previewDiagnosticsIncludeSurfacePressureAndSurfaceCacheState() async throws {
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let surfaceCandidate = HrrrRunCandidate(
            runTime: makeTruncatedToHour(now),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let expectedSurfaceCandidate = HrrrRunCandidate(
            model: pressureCandidate.model,
            product: .wrfsfc,
            domain: pressureCandidate.domain,
            runTime: pressureCandidate.runTime,
            forecastHour: pressureCandidate.forecastHour,
            fieldSetVersion: .anvilSurfaceV1
        )
        let expectedCentroid = try DefaultStormSetupH3Resolver().resolve(h3Cell: h3Cell).centroid
        let loggerContext = makeCapturingLogger(label: "preview-surface-success")
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            makePreviewPressureSourceResolution(
                candidate: pressureCandidate,
                idxAvailable: true
            )
        }
        let surfaceProfileLoader = PreviewStubSurfaceProfileLoader { _, resolution, centroid in
            #expect(resolution.targetValidTime == makeTruncatedToHour(now))
            #expect(resolution.candidates == [pressureCandidate])
            #expect(centroid == expectedCentroid)
            return previewMakeSurfaceProfileLoadResult(
                sourceResolution: HrrrRunResolution(
                    targetValidTime: makeTruncatedToHour(now),
                    candidates: [expectedSurfaceCandidate]
                ),
                fetchedAt: now,
                cacheHit: true,
                samples: previewMakeSurfaceSamples()
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, sourceResolution, centroid, surfaceHeightMslM in
            #expect(sourceResolution.candidate == pressureCandidate)
            #expect(sourceResolution.source.runTime == pressureCandidate.runTime)
            #expect(sourceResolution.source.forecastHour == pressureCandidate.forecastHour)
            #expect(sourceResolution.source.validTime == pressureCandidate.validTime)
            #expect(centroid == expectedCentroid)
            #expect(surfaceHeightMslM == 1_234)
            return previewMakePressureProfileLoadResult(
                sourceResolution: sourceResolution,
                fetchedAt: now,
                subsetCacheHit: false,
                samples: previewMakeEightLevelPressureSamples(),
                surfaceHeightMslM: surfaceHeightMslM
            )
        }
        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: makeFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: makeTruncatedToHour(now), candidates: [surfaceCandidate])
            ),
            surfaceProfileLoader: surfaceProfileLoader,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader,
            logger: loggerContext.logger
        )

        let preview = try await provider.previewProfile(for: h3Cell)
        let sourceSelected = try #require(try loggerContext.event(matching: "Anvil preview exact-cycle surface source selected."))
        let rowIncluded = try #require(try loggerContext.event(matching: "Anvil preview exact-cycle surface row included."))

        #expect(metadataString(sourceSelected.metadata, "pressureSourceRunTime") == pressureCandidate.runTime.ISO8601Format())
        #expect(metadataString(sourceSelected.metadata, "pressureSourceForecastHour") == String(pressureCandidate.forecastHour))
        #expect(metadataString(sourceSelected.metadata, "pressureSourceValidTime") == pressureCandidate.validTime.ISO8601Format())
        #expect(metadataString(sourceSelected.metadata, "surfaceSourceRunTime") == expectedSurfaceCandidate.runTime.ISO8601Format())
        #expect(metadataString(sourceSelected.metadata, "surfaceSourceForecastHour") == String(expectedSurfaceCandidate.forecastHour))
        #expect(metadataString(sourceSelected.metadata, "surfaceSourceValidTime") == expectedSurfaceCandidate.validTime.ISO8601Format())
        #expect(metadataString(sourceSelected.metadata, "surfaceStage") == "selected")
        #expect(metadataString(rowIncluded.metadata, "surfacePressureMb") == "940")
        #expect(metadataString(rowIncluded.metadata, "surfaceSubsetCacheHit") == "true")
        #expect(metadataString(rowIncluded.metadata, "surfaceRowIncluded") == "true")
        #expect(preview.debug.surfacePressureMb == 940)
        #expect(preview.debug.surfaceSubsetCacheHit == true)
        #expect(preview.request.profile.pressureMb.first == 940)
        #expect(preview.request.profile.pressureMb.count == 8)
        #expect(await pressureProfileLoader.callCount == 1)
        #expect(await surfaceProfileLoader.callCount == 1)
        assertNoSensitiveMetadata(in: loggerContext.events)
        assertNoRequestPathSensitiveMetadata(in: loggerContext.events)
        for event in loggerContext.events {
            #expect(event.metadata.keys.contains("selectedPressureLevels") == false)
            #expect(event.metadata.keys.contains("pressureLevelsRequested") == false)
            #expect(event.metadata.keys.contains("pressureLevelsRetained") == false)
        }
    }

    @Test("preview diagnostics report a concise surface rejection reason")
    func previewDiagnosticsReportConciseSurfaceRejectionReason() async throws {
        let now = makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 45)
        let h3Cell: Int64 = 617_700_169_958_293_503
        let surfaceCandidate = HrrrRunCandidate(
            runTime: makeTruncatedToHour(now),
            forecastHour: 0
        )
        let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
        let mismatchCandidate = HrrrRunCandidate(
            product: .wrfsfc,
            runTime: pressureCandidate.runTime.addingTimeInterval(-3_600),
            forecastHour: pressureCandidate.forecastHour
        )
        let loggerContext = makeCapturingLogger(label: "preview-surface-rejection")
        let pressureSourceResolver = PreviewStubPressureSourceResolver { _, _ in
            makePreviewPressureSourceResolution(
                candidate: pressureCandidate,
                idxAvailable: true
            )
        }
        let surfaceProfileLoader = PreviewStubSurfaceProfileLoader { _, _, _ in
            previewMakeSurfaceProfileLoadResult(
                sourceResolution: HrrrRunResolution(
                    targetValidTime: makeTruncatedToHour(now),
                    candidates: [mismatchCandidate]
                ),
                fetchedAt: now,
                cacheHit: false,
                samples: previewMakeSurfaceSamples()
            )
        }
        let pressureProfileLoader = PreviewStubPressureProfileLoader { _, _, _, _ in
            Issue.record("Pressure profile loading should not have been reached after a surface mismatch.")
            throw AnvilProfilePreviewError.upstreamUnavailable(reason: "unexpected pressure load")
        }
        let provider = DefaultAnvilProfilePreviewProvider(
            h3Resolver: DefaultStormSetupH3Resolver(),
            dateProvider: makeFixedStormSetupDateProvider(nowDate: now),
            hrrrRunResolver: PreviewStaticHrrrRunResolver(
                resolution: HrrrRunResolution(targetValidTime: makeTruncatedToHour(now), candidates: [surfaceCandidate])
            ),
            surfaceProfileLoader: surfaceProfileLoader,
            pressureSourceResolver: pressureSourceResolver,
            pressureProfileLoader: pressureProfileLoader,
            logger: loggerContext.logger
        )

        do {
            _ = try await provider.previewProfile(for: h3Cell)
            Issue.record("Expected a surface source mismatch to fail.")
        } catch let error as AnvilProfilePreviewError {
            if case .unusableProfile(let reason) = error {
                #expect(reason.contains("Matching surface source identity"))
            } else {
                Issue.record("Expected unusable profile error but got \(error).")
            }
        }

        let rejected = try #require(try loggerContext.event(matching: "Anvil preview exact-cycle surface row rejected."))
        #expect(metadataString(rejected.metadata, "surfaceStage") == "mismatched")
        #expect(metadataString(rejected.metadata, "surfaceRowIncluded") == "false")
        #expect(metadataString(rejected.metadata, "reason")?.contains("Matching surface source identity") == true)
        #expect(rejected.metadata.keys.contains("selectedPressureLevels") == false)
        #expect(rejected.metadata.keys.contains("pressureLevelsRequested") == false)
        #expect(rejected.metadata.keys.contains("pressureLevelsRetained") == false)
        #expect(rejected.metadata.keys.contains("h3") == false)
        #expect(rejected.metadata.keys.contains("latitude") == false)
        #expect(rejected.metadata.keys.contains("longitude") == false)
        #expect(await pressureProfileLoader.callCount == 0)
        assertNoSensitiveMetadata(in: loggerContext.events)
        assertNoRequestPathSensitiveMetadata(in: loggerContext.events)
    }
}

private extension PressureArtifactDiagnosticsTests {
    func withApp(
        test: (Application, NIOThreadPoolPressureArtifactBlockingWorkExecutor) async throws -> Void
    ) async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                try await clearCatalog(on: app.db)
                let blockingWorkExecutor = makePressureArtifactBlockingWorkExecutor(application: app)
                try await test(app, blockingWorkExecutor)
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    func seedCatalogRow(
        status: PressureArtifactCatalogStatus,
        payload: PressureArtifactWarmJobPayload,
        on db: any Database
    ) async throws {
        try await PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: status,
            source: .aws
        ).create(on: db)
    }

    func makeWarmPayload() -> PressureArtifactWarmJobPayload {
        let runTime = makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
        return PressureArtifactWarmJobPayload(
            runTime: runTime,
            forecastHour: 9,
            validTime: runTime.addingTimeInterval(9 * 3_600),
            product: .wrfprsf,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makePressureCandidate(runTime: Date, forecastHour: Int) -> HrrrRunCandidate {
        HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makePayload(from candidate: HrrrRunCandidate) -> PressureArtifactWarmJobPayload {
        PressureArtifactWarmJobPayload(
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: candidate.validTime,
            product: candidate.product,
            fieldSetVersion: candidate.fieldSetVersion
        )
    }

    func makeSurfaceCandidate(
        runTime: Date,
        forecastHour: Int
    ) -> HrrrRunCandidate {
        HrrrRunCandidate(
            product: .wrfprsf,
            runTime: runTime,
            forecastHour: forecastHour,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makePressureCandidate(from surfaceCandidate: HrrrRunCandidate) -> HrrrRunCandidate {
        HrrrRunCandidate(
            model: surfaceCandidate.model,
            product: .wrfprsf,
            domain: surfaceCandidate.domain,
            runTime: StormSetupUTC.calendar.date(byAdding: .hour, value: -1, to: surfaceCandidate.runTime) ?? surfaceCandidate.runTime,
            forecastHour: surfaceCandidate.forecastHour + 1,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makeSourceURLs(for payload: PressureArtifactWarmJobPayload) -> (idx: URL, grib: URL) {
        let candidate = HrrrRunCandidate(
            product: payload.product,
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            fieldSetVersion: payload.fieldSetVersion
        )
        let builder = HrrrPressureDirectObjectURLBuilder()
        return (idx: builder.makeIdxURL(for: candidate), grib: builder.makeGribURL(for: candidate))
    }

    func makeInventoryText() -> String {
        makeCompleteInventoryText()
    }

    func makeRangeResponses(for payload: PressureArtifactWarmJobPayload) -> [String: HTTPResponse] {
        let sourceURLs = makeSourceURLs(for: payload)
        let inventory = HrrrPressureIdxInventory.parse(makeCompleteInventoryText())
        let selection = HrrrPressureProfileMessageSelector().select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)

        return Dictionary(uniqueKeysWithValues: plan.ranges.enumerated().map { index, range in
            let body = Data(repeating: UInt8(65 + (index % 26)), count: 4)
            let contentRange = range.closedRange.map { "bytes \($0.lowerBound)-\($0.upperBound)/\(range.startOffset + 4)" } ?? "bytes \(range.startOffset)-\(range.startOffset + 3)/\(range.startOffset + 4)"
            return (
                sourceURLs.grib.absoluteString + "|" + range.httpRangeHeaderValue,
                HTTPResponse(
                    status: 206,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Range": contentRange
                    ],
                    data: body
                )
            )
        })
    }

    func makeCompleteInventoryText() -> String {
        var lines: [String] = []
        lines.reserveCapacity(StormSetupPressureLevel.preferredDescending.count * StormSetupPressureProfileVariable.allCases.count)

        var messageNumber = 1
        var byteOffset: Int64 = 0
        for level in StormSetupPressureLevel.preferredDescending {
            for variable in StormSetupPressureProfileVariable.allCases {
                lines.append("\(messageNumber):\(byteOffset):d=2026060313:\(variable.rawValue):\(level.pressureMb) mb:9 hour fcst:")
                messageNumber += 1
                byteOffset += 4
            }
        }

        return lines.joined(separator: "\n")
    }

    func makeExpectedValidationLineCount() -> Int {
        HrrrPressureProfileMessageSelector()
            .select(inventory: HrrrPressureIdxInventory.parse(makeCompleteInventoryText()))
            .selectedMessages
            .count
    }

    func makeTempRegularFile(contents: Data) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-diagnostics-\(UUID().uuidString).grib2")
        FileManager.default.createFile(atPath: url.path, contents: contents)
        return url
    }

    func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-diagnostics-\(UUID().uuidString)", isDirectory: true)
    }

    func makeUTCDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        let components = DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )

        guard let date = StormSetupUTC.calendar.date(from: components) else {
            preconditionFailure("Unable to create UTC date for test.")
        }

        return date
    }

    func makeTruncatedToHour(_ date: Date) -> Date {
        StormSetupUTC.calendar.date(
            from: DateComponents(
                timeZone: TimeZone(secondsFromGMT: 0),
                year: StormSetupUTC.calendar.component(.year, from: date),
                month: StormSetupUTC.calendar.component(.month, from: date),
                day: StormSetupUTC.calendar.component(.day, from: date),
                hour: StormSetupUTC.calendar.component(.hour, from: date)
            )
        ) ?? date
    }

    func makePreviewPressureSourceResolution(
        candidate: HrrrRunCandidate,
        idxAvailable: Bool
    ) -> HrrrPressureDirectObjectResolution {
        let builder = HrrrPressureDirectObjectURLBuilder()
        let source = builder.makeSourceMetadata(for: candidate)
        let idxURL = source.idxURL ?? builder.makeIdxURL(for: candidate)

        return HrrrPressureDirectObjectResolution(
            candidate: candidate,
            source: source,
            idxProbe: HrrrRemoteObjectProbeResult(
                url: idxURL,
                available: idxAvailable,
                status: idxAvailable ? 200 : 404
            ),
            gribProbe: nil
        )
    }

    func makeCapturingLogger(label: String) -> CapturingLoggerContext {
        let handler = CapturingLogHandler()
        let logger = Logger(label: label, factory: { _ in handler })
        return CapturingLoggerContext(logger: logger, handler: handler)
    }

    func makeFixedStormSetupDateProvider(nowDate: Date) -> some StormSetupDateProviding {
        FixedStormSetupDateProvider(nowDate: nowDate)
    }

    func metadataString(_ metadata: Logger.Metadata, _ key: String) -> String? {
        guard let value = metadata[key] else {
            return nil
        }

        switch value {
        case .string(let value):
            return value
        case .stringConvertible(let value):
            return String(describing: value)
        case .dictionary(let dictionary):
            return String(describing: dictionary)
        case .array(let array):
            return String(describing: array)
        }
    }

    func assertNoSensitiveMetadata(in events: [CapturedLogEvent]) {
        for event in events {
            #expect(event.metadata.keys.contains("h3") == false)
            #expect(event.metadata.keys.contains("latitude") == false)
            #expect(event.metadata.keys.contains("longitude") == false)
        }
    }

    func assertNoRequestPathSensitiveMetadata(in events: [CapturedLogEvent]) {
        for event in events {
            #expect(event.metadata.keys.contains("primaryDownloadURL") == false)
            #expect(event.metadata.keys.contains("idxURL") == false)
            #expect(event.metadata.keys.contains("sourceURL") == false)
            #expect(event.metadata.keys.contains("localPath") == false)
            #expect(event.metadata.keys.contains("claimToken") == false)
            #expect(event.metadata.keys.contains("requestPayload") == false)
            #expect(event.metadata.keys.contains("coordinates") == false)
        }
    }

    func makeSnapshot(
        h3Cell: Int64,
        source: StormSetupSourceMetadata,
        fetchedAt: Date,
        assessment: TornadoIngredientAssessment,
        freshness: IngredientFreshness
    ) -> TornadoIngredientSnapshot {
        TornadoIngredientSnapshot(
            h3Cell: h3Cell,
            centroid: StormSetupCentroid(latitude: 39.7825, longitude: -104.4661),
            source: source,
            raw: makeRaw(),
            assessment: assessment,
            freshness: freshness
        )
    }

    func makeSourceMetadataForRequest(validTime: Date?) -> StormSetupSourceMetadata {
        StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: validTime,
            forecastHour: 0,
            validTime: validTime,
            fieldSetVersion: .tornadoV1,
            nomadsURL: URL(string: "https://example.com/surface.grib2")
        )
    }

    func makeSurfaceSource(
        runTime: Date,
        forecastHour: Int,
        validTime: Date
    ) -> StormSetupSourceMetadata {
        StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            fieldSetVersion: .tornadoV1,
            nomadsURL: URL(string: "https://example.com/surface.grib2")
        )
    }

    func makeSurfaceSourceWithoutValidTime() -> StormSetupSourceMetadata {
        StormSetupSourceMetadata(
            model: .hrrr,
            product: .wrfsfc,
            domain: .conus,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
            forecastHour: 0,
            validTime: nil,
            fieldSetVersion: .tornadoV1,
            nomadsURL: URL(string: "https://example.com/surface.grib2")
        )
    }

    func makeFreshness(
        sourceValidTime: Date?,
        fetchedAt: Date,
        sourceRunTime: Date? = nil,
        forecastHour: Int? = nil
    ) -> IngredientFreshness {
        IngredientFreshness(
            sourceValidTime: sourceValidTime,
            modelRunTime: sourceRunTime,
            forecastHour: forecastHour,
            fetchedAt: fetchedAt,
            expiresAt: (sourceValidTime ?? sourceRunTime ?? fetchedAt).addingTimeInterval(90 * 60),
            isStale: sourceValidTime.map { fetchedAt >= $0.addingTimeInterval(90 * 60) } ?? true,
            isDegraded: sourceValidTime == nil || sourceRunTime == nil || forecastHour == nil
        )
    }

    func makeAssessment() -> TornadoIngredientAssessment {
        TornadoIngredientInterpreter().assess(
            raw: makeRaw(
                sbcapeJkg: 1450,
                mlcapeJkg: 1200,
                mucapeJkg: 1600,
                mlcinJkg: -35,
                mllclM: 950,
                shear06kmKt: 42,
                srh01kmM2s2: 80,
                srh03kmM2s2: 160
            ),
            freshness: makeFreshness(
                sourceValidTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22),
                fetchedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 22, minute: 15)
            ),
            evidence: nil
        )
    }

    func makeNormalizationResult(raw: TornadoRawParameters) -> TornadoIngredientNormalizationResult {
        TornadoIngredientNormalizationResult(raw: raw, diagnostics: [])
    }

    func makeRaw(
        sbcapeJkg: Double? = nil,
        mlcapeJkg: Double? = nil,
        mucapeJkg: Double? = nil,
        mlcinJkg: Double? = nil,
        mllclM: Double? = nil,
        shear06kmKt: Double? = nil,
        srh01kmM2s2: Double? = nil,
        srh03kmM2s2: Double? = nil
    ) -> TornadoRawParameters {
        TornadoRawParameters(
            sbcapeJkg: sbcapeJkg,
            mlcapeJkg: mlcapeJkg,
            mucapeJkg: mucapeJkg,
            mlcinJkg: mlcinJkg,
            dcapeJkg: nil,
            mllclM: mllclM,
            tempDewPtDeltaF: nil,
            threeCapeJkg: nil,
            lclLfcSeparationM: nil,
            lapseRate03kmCkm: nil,
            lapseRate700500mbCkm: nil,
            shear06kmKt: shear06kmKt,
            shear03kmKt: nil,
            shear01kmKt: nil,
            effectiveShearKt: nil,
            srh01kmM2s2: srh01kmM2s2,
            srh03kmM2s2: srh03kmM2s2,
            effectiveSrhM2s2: nil,
            supercellComposite: nil,
            significantTornadoFixed: nil,
            significantTornadoEffective: nil,
            significantHail: nil,
            bunkersRightMotion: nil,
            bunkersLeftMotion: nil,
            stormRelativeWind46km: nil,
            meanWind850300mb: nil,
            diagnostics: []
        )
    }

    func makeAnalysisResponse(
        requestValidTime: Date,
        debugRunTime: Date,
        debugForecastHour: Int,
        debugValidTime: Date,
        effectiveLayerStatus: String,
        stormMotionStatus: String,
        warnings: [String]
    ) -> AnvilAnalyzeProfileAnalysisResponse {
        let request = AnvilAnalyzeProfileRequest(
            runTime: debugRunTime,
            forecastHour: debugForecastHour,
            validTime: requestValidTime,
            location: AnvilLocationDTO(lat: 39.78, lon: -104.46, h3: "88268b1ffffffff"),
            profile: AnvilProfileDTO(
                pressureMb: [1000, 925, 850, 700, 600, 500, 400, 300],
                heightMslM: [1200, 1500, 1800, 2450, 4100, 5600, 7100, 9300],
                temperatureC: [28, 22, 17, 10, 3, -4, -15, -27],
                dewpointC: [12, 10, 9, 1, -4, -9, -17, -24],
                uWindMs: [-2, -5, -6, -12, -15, -18, -23, -29],
                vWindMs: [4, 7, 8, 14, 18, 22, 27, 33]
            )
        )

        let debug = AnvilAnalyzeProfilePreviewDebugDTO(
            sourceKind: .directObject,
            product: .wrfprsf,
            runTime: debugRunTime,
            forecastHour: debugForecastHour,
            validTime: debugValidTime,
            h3: "88268b1ffffffff",
            centroid: StormSetupCentroid(latitude: 39.78, longitude: -104.46),
            selectedMessageCount: 0,
            selectedPressureLevels: [],
            surfacePressureMb: 940,
            surfaceSubsetCacheHit: false,
            rangeCount: 0,
            totalSelectedRangeBytes: 0,
            pressureLevelsRequested: [],
            pressureLevelsRetained: [],
            missingLevels: [],
            warnings: warnings,
            subsetCacheHit: true,
            primaryDownloadURL: nil,
            idxURL: nil,
            idxAvailable: nil,
            gribAvailable: nil
        )

        let response = AnvilAnalyzeProfileResponse(
            effectiveLayer: AnvilEffectiveLayerDTO(
                status: effectiveLayerStatus,
                basePressureMb: 1000,
                topPressureMb: 700,
                baseMetersAgl: 0,
                topMetersAgl: 3000
            ),
            stormMotion: AnvilStormMotionDTO(
                status: stormMotionStatus,
                bunkersRight: AnvilBunkersRightStormMotionDTO(
                    uKt: 20,
                    vKt: 25,
                    speedKt: 32,
                    directionTowardDeg: 215,
                    uMs: 10,
                    vMs: 12,
                    speedMs: 16
                )
            ),
            mucape: 1800,
            mlcape: 1400,
            mlcin: -35,
            mllclMetersAgl: 950,
            effectiveSrh: 130,
            effectiveBulkShearMs: 22,
            scp: 1.2,
            stpCin: 1.1,
            stpFixed: 0.9,
            ship: 1.3,
            quality: AnvilQualityDTO(profileLevelCount: 37, warnings: warnings)
        )

        return AnvilAnalyzeProfileAnalysisResponse(request: request, debug: debug, response: response)
    }
}

private final class CapturingLogHandler: LogHandler, @unchecked Sendable {
    private let lock = NSLock()
    private var _logLevel: Logger.Level = .trace
    private var _metadata: Logger.Metadata = [:]
    private var _events: [CapturedLogEvent] = []

    var logLevel: Logger.Level {
        get { lock.withLock { _logLevel } }
        set { lock.withLock { _logLevel = newValue } }
    }

    var metadata: Logger.Metadata {
        get { lock.withLock { _metadata } }
        set { lock.withLock { _metadata = newValue } }
    }

    subscript(metadataKey metadataKey: String) -> Logger.MetadataValue? {
        get { lock.withLock { _metadata[metadataKey] } }
        set { lock.withLock { _metadata[metadataKey] = newValue } }
    }

    var events: [CapturedLogEvent] {
        lock.withLock { _events }
    }

    func log(
        level: Logger.Level,
        message: Logger.Message,
        metadata: Logger.Metadata?,
        source: String,
        file: String,
        function: String,
        line: UInt
    ) {
        _ = source
        _ = file
        _ = function
        _ = line
        let event = CapturedLogEvent(
            level: level,
            message: message.description,
            metadata: metadata ?? self.metadata
        )
        lock.withLock {
            _events.append(event)
        }
    }
}

private struct CapturedLogEvent: Sendable, Equatable {
    let level: Logger.Level
    let message: String
    let metadata: Logger.Metadata
}

private struct CapturingLoggerContext {
    let logger: Logger
    let handler: CapturingLogHandler

    var events: [CapturedLogEvent] {
        handler.events
    }

    func event(matching message: String) throws -> CapturedLogEvent? {
        events.first { $0.message == message }
    }
}

private struct FixedHrrrRunResolving: HrrrRunResolving {
    let resolution: HrrrRunResolution

    func resolveRunCandidates() -> HrrrRunResolution {
        resolution
    }
}

private final class ProbeWarmJobDispatcherRecorder: PressureArtifactWarmJobDispatching, @unchecked Sendable {
    private let lock = NSLock()
    private var _dispatches: [(queueName: String, payload: PressureArtifactWarmJobPayload)] = []

    var dispatches: [(queueName: String, payload: PressureArtifactWarmJobPayload)] {
        lock.withLock { _dispatches }
    }

    func dispatch(
        _ payload: PressureArtifactWarmJobPayload,
        to queueName: QueueName,
        on application: Application
    ) async throws {
        _ = application
        lock.withLock {
            _dispatches.append((queueName: queueName.string, payload: payload))
        }
    }
}

private final class ProbeStubHrrrRemoteObjectChecking: HrrrRemoteObjectChecking, @unchecked Sendable {
    private let availableURLs: [String: Bool]
    private let lock = NSLock()
    private var _requestedURLs: [String] = []

    init(availableURLs: [String: Bool]) {
        self.availableURLs = availableURLs
    }

    var requestedURLs: [String] {
        lock.withLock { _requestedURLs }
    }

    func probe(url: URL) async throws -> HrrrRemoteObjectProbeResult {
        lock.withLock {
            _requestedURLs.append(url.absoluteString)
        }

        let available = availableURLs[url.absoluteString] ?? false
        return HrrrRemoteObjectProbeResult(
            url: url,
            available: available,
            status: available ? 200 : 404
        )
    }
}

private final class PressureArtifactWarmHTTPClient: App.HTTPClient, @unchecked Sendable {
    private let idxResponses: [String: Data]
    private let rangeResponses: [String: HTTPResponse]

    init(
        idxResponses: [String: Data] = [:],
        rangeResponses: [String: HTTPResponse] = [:]
    ) {
        self.idxResponses = idxResponses
        self.rangeResponses = rangeResponses
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        if headers["Range"] == nil {
            guard let data = idxResponses[url.absoluteString] else {
                throw URLError(.badServerResponse)
            }
            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                data: data
            )
        }

        let key = url.absoluteString + "|" + (headers["Range"] ?? "")
        guard let response = rangeResponses[key] else {
            throw URLError(.badServerResponse)
        }

        return response
    }

    func head(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func post(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers)
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String : String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await post(url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    }

    func clearCache() {}
}

private final class PressureArtifactWarmValidatorStub: PressureArtifactValidating, @unchecked Sendable {
    private let error: (any Error)?
    private let lineCount: Int

    init(error: (any Error)? = nil, lineCount: Int) {
        self.error = error
        self.lineCount = lineCount
    }

    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult {
        _ = localFileURL
        if let error {
            throw error
        }
        return PressureArtifactValidationResult(stdoutLineCount: lineCount)
    }
}

private enum PressureArtifactWarmValidatorStubError: Error, CustomStringConvertible {
    case failedValidation

    var description: String {
        "failedValidation"
    }
}

private actor StubStormSetupSnapshotCache: StormSetupSnapshotCaching {
    private let snapshot: TornadoIngredientSnapshot?

    init(snapshot: TornadoIngredientSnapshot?) {
        self.snapshot = snapshot
    }

    func loadSnapshot(for key: StormSetupSnapshotCacheKey) async -> StormSetupSnapshotCacheResult? {
        _ = key
        guard let snapshot else {
            return nil
        }

        return StormSetupSnapshotCacheResult(
            snapshot: snapshot,
            cacheHit: true,
            fetchedAt: snapshot.freshness.fetchedAt,
            expiresAt: snapshot.freshness.expiresAt,
            sourceValidTime: snapshot.freshness.sourceValidTime,
            rulesVersion: .current
        )
    }

    func store(snapshot: TornadoIngredientSnapshot, for key: StormSetupSnapshotCacheKey) async throws -> StormSetupSnapshotCacheResult {
        _ = snapshot
        _ = key
        return StormSetupSnapshotCacheResult(
            snapshot: snapshot,
            cacheHit: true,
            fetchedAt: snapshot.freshness.fetchedAt,
            expiresAt: snapshot.freshness.expiresAt,
            sourceValidTime: snapshot.freshness.sourceValidTime,
            rulesVersion: .current
        )
    }
}

private struct UnusedStormSetupSubsetLoader: StormSetupSubsetLoading {
    func loadFirstAvailableSubset(
        for resolution: HrrrRunResolution,
        around centroid: StormSetupCentroid
    ) async throws -> GribSubsetCacheResult {
        throw TestFailure.unexpectedDownstreamCall("subset loader should not run in request-path diagnostics")
    }
}

private struct UnusedStormSetupFieldSampler: StormSetupFieldSampling {
    func sample(from subset: GribSubsetCacheResult, around centroid: StormSetupCentroid) async throws -> [HrrrFieldSample] {
        throw TestFailure.unexpectedDownstreamCall("field sampler should not run in request-path diagnostics")
    }

    func sample(localFileURL: URL, around centroid: StormSetupCentroid) async throws -> [HrrrFieldSample] {
        throw TestFailure.unexpectedDownstreamCall("field sampler should not run in request-path diagnostics")
    }
}

private struct StubStormSetupNormalizer: StormSetupIngredientNormalizing {
    let result: TornadoIngredientNormalizationResult

    func normalize(samples: [HrrrFieldSample]) -> TornadoIngredientNormalizationResult {
        _ = samples
        return result
    }
}

private struct StaticAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let response: AnvilAnalyzeProfileAnalysisResponse

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        return response
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

private struct ThrowingAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let error: any Error

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        throw error
    }
}

private struct SuspendedAnvilProfileAnalysisProvider: AnvilProfileAnalysisProviding, @unchecked Sendable {
    let response: AnvilAnalyzeProfileAnalysisResponse

    func analyzeProfile(for h3Cell: Int64) async throws -> AnvilAnalyzeProfileAnalysisResponse {
        _ = h3Cell
        try await Task.sleep(for: .seconds(10))
        return response
    }
}

private enum TestFailure: Error, Sendable {
    case unexpectedDownstreamCall(String)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
