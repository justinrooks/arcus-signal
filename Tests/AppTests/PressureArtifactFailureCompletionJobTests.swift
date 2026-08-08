@testable import App
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor
import XCTQueues
import ArcusCore

@Suite("Pressure artifact failure completion job", .serialized)
struct PressureArtifactFailureCompletionJobTests {
    @Test("failed fenced completion is durably retried and later succeeds")
    func failedCompletionIsDurablyRetriedAndLaterSucceeds() async throws {
        try await withApp { app, blockingWorkExecutor in
            let completer = SequencedFailureCompleter(failuresBeforeSuccess: 2)
            app.queues.add(PressureArtifactFailureCompletionJob(completer: completer))
            let artifact = makeArtifactPayload()
            try await seedCatalogRow(status: .pending, artifact: artifact, on: app.db)

            let service = PressureArtifactWarmingService(
                httpClient: IncompleteInventoryHTTPClient(),
                blockingWorkExecutor: blockingWorkExecutor,
                validator: UnusedPressureArtifactValidator(),
                cacheRootURL: testRootURL(),
                dateProvider: FixedFailureCompletionDateProvider(nowDate: artifact.runTime),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024,
                failureCompleter: completer
            )

            await #expect(throws: PressureArtifactFailureDispositionError.self) {
                try await service.warm(payload: artifact, on: app, logger: app.logger)
            }

            let queuedPayload = try #require(
                app.queues.test.first(PressureArtifactFailureCompletionJob.self)
            )
            var row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(row.status == .warming)
            #expect(row.claimToken == queuedPayload.claimToken)
            #expect(row.leaseExpiresAt != nil)

            let queue = app.queues.queue(ArcusQueueLane.modelArtifacts.queueName)
            try await queue.worker.run()
            #expect(await completer.attemptCount == 2)
            #expect(app.queues.test.contains(PressureArtifactFailureCompletionJob.self))

            makeDelayedCompletionJobsReady(on: app)
            try await queue.worker.run()

            row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(await completer.attemptCount == 3)
            #expect(row.status == .failed)
            #expect(row.claimToken == nil)
            #expect(row.leaseExpiresAt == nil)
            #expect(row.errorSummary == queuedPayload.errorSummary)
            #expect(app.queues.test.contains(PressureArtifactFailureCompletionJob.self) == false)
        }
    }

    @Test("failed durable dispatch remains an explicit warm failure")
    func failedDurableDispatchRemainsExplicitWarmFailure() async throws {
        try await withApp { app, blockingWorkExecutor in
            let artifact = makeArtifactPayload()
            try await seedCatalogRow(status: .pending, artifact: artifact, on: app.db)
            let service = PressureArtifactWarmingService(
                httpClient: IncompleteInventoryHTTPClient(),
                blockingWorkExecutor: blockingWorkExecutor,
                validator: UnusedPressureArtifactValidator(),
                cacheRootURL: testRootURL(),
                dateProvider: FixedFailureCompletionDateProvider(nowDate: artifact.runTime),
                retentionDuration: 12 * 60 * 60,
                maximumByteCount: 1024,
                failureCompleter: SequencedFailureCompleter(failuresBeforeSuccess: .max),
                failureCompletionDispatcher: ThrowingFailureCompletionDispatcher()
            )

            do {
                try await service.warm(payload: artifact, on: app, logger: app.logger)
                Issue.record("Expected durable completion dispatch to fail.")
            } catch let error as PressureArtifactFailureCompletionError {
                guard case .dispatchFailed(let errorType) = error else {
                    Issue.record("Expected dispatch failure but received \(error).")
                    return
                }
                #expect(errorType == String(describing: FailureCompletionTestError.self))
            }

            let row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(row.status == .warming)
            #expect(row.claimToken != nil)
            #expect(row.leaseExpiresAt != nil)
            #expect(app.queues.test.jobs.isEmpty)
        }
    }

    @Test("duplicate completion jobs are idempotent")
    func duplicateCompletionJobsAreIdempotent() async throws {
        try await withApp { app, _ in
            let artifact = makeArtifactPayload()
            let claimToken = UUID()
            try await seedCatalogRow(
                status: .warming,
                artifact: artifact,
                claimToken: claimToken,
                on: app.db
            )
            let payload = makeCompletionPayload(artifact: artifact, claimToken: claimToken)
            let dispatcher = DefaultPressureArtifactFailureCompletionJobDispatcher()

            try await dispatcher.dispatch(payload, on: app)
            try await dispatcher.dispatch(payload, on: app)
            try await app.queues.queue(ArcusQueueLane.modelArtifacts.queueName).worker.run()

            let row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(row.status == .failed)
            #expect(row.claimToken == nil)
            #expect(row.leaseExpiresAt == nil)
            #expect(row.errorSummary == payload.errorSummary)
            #expect(app.queues.test.jobs.isEmpty)
        }
    }

    @Test("stale completion cannot mutate a newer owner")
    func staleCompletionCannotMutateNewerOwner() async throws {
        try await withApp { app, _ in
            let artifact = makeArtifactPayload()
            let newerClaimToken = UUID()
            let leaseExpiresAt = artifact.runTime.addingTimeInterval(1_800)
            try await seedCatalogRow(
                status: .warming,
                artifact: artifact,
                claimToken: newerClaimToken,
                leaseExpiresAt: leaseExpiresAt,
                on: app.db
            )

            try await DefaultPressureArtifactFailureCompletionJobDispatcher().dispatch(
                makeCompletionPayload(artifact: artifact, claimToken: UUID()),
                on: app
            )
            try await app.queues.queue(ArcusQueueLane.modelArtifacts.queueName).worker.run()

            let row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(row.status == .warming)
            #expect(row.claimToken == newerClaimToken)
            #expect(row.leaseExpiresAt == leaseExpiresAt)
            #expect(row.errorSummary == nil)
        }
    }

    @Test("retry exhaustion preserves lease recovery and emits safe evidence")
    func retryExhaustionPreservesLeaseRecoveryAndEmitsSafeEvidence() async throws {
        try await withApp { app, _ in
            let loggerContext = makeCapturingLogger(label: "failure-completion-exhaustion")
            app.logger = loggerContext.logger
            let completer = SequencedFailureCompleter(failuresBeforeSuccess: .max)
            app.queues.add(PressureArtifactFailureCompletionJob(completer: completer))
            let artifact = makeArtifactPayload()
            let claimToken = UUID()
            let leaseExpiresAt = artifact.runTime.addingTimeInterval(1_800)
            try await seedCatalogRow(
                status: .warming,
                artifact: artifact,
                claimToken: claimToken,
                leaseExpiresAt: leaseExpiresAt,
                on: app.db
            )
            let sensitivePath = "/private/tmp/secret-pressure-artifact.grib2"
            let rawFailure = SensitiveFailure(
                description: "failed at \(sensitivePath) for \(claimToken.uuidString)"
            )
            let payload = PressureArtifactFailureCompletionJobPayload(
                artifact: artifact,
                claimToken: claimToken,
                errorSummary: PressureArtifactFailureSummary.sanitized(
                    from: rawFailure,
                    claimToken: claimToken
                )
            )

            try await DefaultPressureArtifactFailureCompletionJobDispatcher().dispatch(payload, on: app)
            let queue = app.queues.queue(ArcusQueueLane.modelArtifacts.queueName)
            let retryPolicy = PressureArtifactFailureCompletionRetryPolicy()
            for attempt in 0...retryPolicy.maximumRetryCount {
                try await queue.worker.run()
                if attempt < retryPolicy.maximumRetryCount {
                    makeDelayedCompletionJobsReady(on: app)
                }
            }

            let row = try #require(try await findCatalogRow(artifact, on: app.db))
            #expect(await completer.attemptCount == retryPolicy.maximumRetryCount + 1)
            #expect(row.status == .warming)
            #expect(row.claimToken == claimToken)
            #expect(row.leaseExpiresAt == leaseExpiresAt)
            #expect(row.errorSummary == nil)
            #expect(app.queues.test.jobs.isEmpty)
            #expect(loggerContext.events.contains {
                $0.message == "Pressure artifact failure completion exhausted retries."
            })
            assertLogsDoNotContain(
                [claimToken.uuidString, sensitivePath, payload.errorSummary],
                events: loggerContext.events
            )
        }
    }

    @Test("completion propagates cancellation")
    func completionPropagatesCancellation() async throws {
        let app = try await Application.make(.testing)
        let job = PressureArtifactFailureCompletionJob(
            completer: CancellingFailureCompleter()
        )

        await #expect(throws: CancellationError.self) {
            try await job.dequeue(
                makeQueueContext(app: app),
                makeCompletionPayload(artifact: makeArtifactPayload(), claimToken: UUID())
            )
        }

        try await app.asyncShutdown()
    }

    @Test("retry schedule and summary sanitization are bounded")
    func retryScheduleAndSummarySanitizationAreBounded() {
        let retryPolicy = PressureArtifactFailureCompletionRetryPolicy()
        let job = PressureArtifactFailureCompletionJob(retryPolicy: retryPolicy)
        #expect((1...3).map(job.nextRetryIn(attempt:)) == [15, 60, 300])
        #expect(retryPolicy.maximumRetryCount == 3)
        #expect(retryPolicy.delaysSeconds.allSatisfy { $0 > 0 })

        let claimToken = UUID()
        let path = "/private/tmp/secret.grib2"
        let url = "https://example.com/private-source"
        let longReason = String(repeating: "x", count: 600)
        let summary = PressureArtifactFailureSummary.sanitized(
            from: SensitiveFailure(
                description: "\(claimToken.uuidString) \(path) \(url) \(longReason)"
            ),
            claimToken: claimToken
        )

        #expect(summary.contains(claimToken.uuidString) == false)
        #expect(summary.contains(path) == false)
        #expect(summary.contains(url) == false)
        #expect(summary.count == PressureArtifactFailureSummary.maximumLength)
    }

    @Test("configured retry schedule controls job delays and dispatch retry count")
    func configuredRetryScheduleControlsJobAndDispatch() async throws {
        try await withApp { app, _ in
            let configuration = StormSetupConfiguration.resolved(from: [
                "STORM_SETUP_PRESSURE_ARTIFACT_FAILURE_COMPLETION_RETRY_DELAYS_SECONDS": "4, 9"
            ])
            app.stormSetupConfiguration = configuration
            let retryPolicy = configuration.pressureArtifactFailureCompletionRetryPolicy
            let job = PressureArtifactFailureCompletionJob(retryPolicy: retryPolicy)
            app.queues.add(job)

            try await DefaultPressureArtifactFailureCompletionJobDispatcher().dispatch(
                makeCompletionPayload(artifact: makeArtifactPayload(), claimToken: UUID()),
                on: app
            )

            let queued = try #require(
                app.queues.test.jobs.values.first {
                    $0.jobName == PressureArtifactFailureCompletionJob.name
                }
            )
            #expect(queued.maxRetryCount == retryPolicy.maximumRetryCount)
            #expect((1...2).map(job.nextRetryIn(attempt:)) == [4, 9])
        }
    }
}

private extension PressureArtifactFailureCompletionJobTests {
    func withApp(
        test: (Application, NIOThreadPoolPressureArtifactBlockingWorkExecutor) async throws -> Void
    ) async throws {
        try await PressureArtifactCatalogTestGate.shared.withExclusiveAccess {
            let app = try await Application.make(.testing)
            do {
                try await configure(app, mode: .api)
                try await app.autoMigrate()
                try await clearCatalog(on: app.db)
                app.queues.use(.test)
                try await test(
                    app,
                    makePressureArtifactBlockingWorkExecutor(application: app)
                )
            } catch {
                try? await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
    }

    func clearCatalog(on database: any Database) async throws {
        guard let sql = database as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }
        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    func seedCatalogRow(
        status: PressureArtifactCatalogStatus,
        artifact: PressureArtifactWarmJobPayload,
        claimToken: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        on database: any Database
    ) async throws {
        try await PressureArtifactCatalogModel(
            runTime: artifact.runTime,
            forecastHour: artifact.forecastHour,
            validTime: artifact.validTime,
            product: artifact.product,
            fieldSetVersion: artifact.fieldSetVersion,
            status: status,
            claimToken: claimToken,
            leaseExpiresAt: leaseExpiresAt
        ).create(on: database)
    }

    func findCatalogRow(
        _ artifact: PressureArtifactWarmJobPayload,
        on database: any Database
    ) async throws -> PressureArtifactCatalogModel? {
        try await PressureArtifactCatalogModel.find(
            runTime: artifact.runTime,
            forecastHour: artifact.forecastHour,
            product: artifact.product,
            fieldSetVersion: artifact.fieldSetVersion,
            on: database
        )
    }

    func makeArtifactPayload() -> PressureArtifactWarmJobPayload {
        let runTime = Date(timeIntervalSince1970: 1_780_488_000)
        return PressureArtifactWarmJobPayload(
            runTime: runTime,
            forecastHour: 9,
            validTime: runTime.addingTimeInterval(9 * 3_600),
            product: .wrfprsf,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makeCompletionPayload(
        artifact: PressureArtifactWarmJobPayload,
        claimToken: UUID
    ) -> PressureArtifactFailureCompletionJobPayload {
        PressureArtifactFailureCompletionJobPayload(
            artifact: artifact,
            claimToken: claimToken,
            errorSummary: "pressure acquisition failed"
        )
    }

    func makeQueueContext(app: Application) -> QueueContext {
        QueueContext(
            queueName: ArcusQueueLane.modelArtifacts.queueName,
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    func makeDelayedCompletionJobsReady(on app: Application) {
        var jobs = app.queues.test.jobs
        for (identifier, data) in jobs where data.jobName == PressureArtifactFailureCompletionJob.name {
            jobs[identifier] = JobData(
                payload: data.payload,
                maxRetryCount: data.maxRetryCount,
                jobName: data.jobName,
                delayUntil: nil,
                queuedAt: data.queuedAt,
                attempts: data.attempts ?? 0
            )
        }
        app.queues.test.jobs = jobs
    }

    func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("failure-completion-\(UUID().uuidString)", isDirectory: true)
    }

    func assertLogsDoNotContain(_ sensitiveValues: [String], events: [CapturedLogEvent]) {
        for event in events {
            let rendered = event.message + String(describing: event.metadata)
            for (index, value) in sensitiveValues.enumerated() {
                #expect(
                    rendered.contains(value) == false,
                    "Sensitive value category \(index) appeared in \(event.message)."
                )
            }
        }
    }
}

private actor SequencedFailureCompleter: PressureArtifactFailureCompleting {
    private let failuresBeforeSuccess: Int
    private(set) var attemptCount = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    func complete(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws -> Bool {
        attemptCount += 1
        if attemptCount <= failuresBeforeSuccess {
            throw FailureCompletionTestError.persistenceUnavailable
        }

        return try await PressureArtifactCatalogStore().markFailed(
            payload: payload.artifact,
            claimToken: payload.claimToken,
            errorSummary: payload.errorSummary,
            on: application.db
        )
    }
}

private struct CancellingFailureCompleter: PressureArtifactFailureCompleting {
    func complete(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws -> Bool {
        throw CancellationError()
    }
}

private struct ThrowingFailureCompletionDispatcher: PressureArtifactFailureCompletionJobDispatching {
    func dispatch(
        _ payload: PressureArtifactFailureCompletionJobPayload,
        on application: Application
    ) async throws {
        throw FailureCompletionTestError.dispatchUnavailable
    }
}

private enum FailureCompletionTestError: Error {
    case persistenceUnavailable
    case dispatchUnavailable
}

private struct SensitiveFailure: Error, CustomStringConvertible {
    let description: String
}

private struct FixedFailureCompletionDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date { nowDate }
}

private struct UnusedPressureArtifactValidator: PressureArtifactValidating {
    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult {
        PressureArtifactValidationResult(stdoutLineCount: 0)
    }
}

private struct IncompleteInventoryHTTPClient: App.HTTPClient {
    func get(
        _ url: URL,
        headers: [String: String],
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        HTTPResponse(
            status: 200,
            headers: ["Content-Type": "text/plain"],
            data: Data("1:0:d=2026060313:HGT:1000 mb:9 hour fcst:".utf8)
        )
    }

    func head(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: nil)
    }

    func post(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await get(url, headers: headers, timeoutSeconds: timeoutSeconds)
    }

    func postWithoutRetry(
        _ url: URL,
        headers: [String: String],
        body: Data?,
        timeoutSeconds: TimeInterval?
    ) async throws -> HTTPResponse {
        try await post(url, headers: headers, body: body, timeoutSeconds: timeoutSeconds)
    }

    func clearCache() {}
}

private final class FailureCompletionCapturingLoggerContext: @unchecked Sendable {
    let logger: Logger
    private let handler: CapturingLogHandler

    init(label: String) {
        let handler = CapturingLogHandler()
        self.handler = handler
        var logger = Logger(label: label, factory: { _ in handler })
        logger.logLevel = .info
        self.logger = logger
    }

    var events: [CapturedLogEvent] { handler.events }
}

private func makeCapturingLogger(label: String) -> FailureCompletionCapturingLoggerContext {
    FailureCompletionCapturingLoggerContext(label: label)
}
