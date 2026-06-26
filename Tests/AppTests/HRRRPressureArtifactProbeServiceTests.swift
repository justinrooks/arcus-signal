@testable import App
import Fluent
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor

@Suite("HRRR pressure artifact probe service", .serialized)
struct HRRRPressureArtifactProbeServiceTests {
    @Test("probe does not enqueue when idx is unavailable and updates lastCheckedAt")
    func probeDoesNotEnqueueWhenIdxIsUnavailableAndUpdatesLastCheckedAt() async throws {
        try await withApp { app in
            let surfaceCandidate = makeSurfaceCandidate()
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking()
            let dispatcher = WarmJobDispatcherRecorder()
            let service = makeService(
                remoteChecker: remoteChecker,
                dispatcher: dispatcher,
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate])
            )

            try await seedCatalogRow(status: .failed, payload: payload, lastCheckedAt: nil, on: app.db)

            try await service.probe(on: app, logger: app.logger)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(dispatcher.dispatches.isEmpty)
            #expect(row.status == .failed)
            #expect(row.lastCheckedAt != nil)
            #expect(remoteChecker.requestedURLs == [makeIdxURL(for: pressureCandidate).absoluteString])
        }
    }

    @Test("probe enqueues PressureArtifactWarmJob when idx is available and the artifact is missing, failed, or expired")
    func probeEnqueuesWarmJobWhenArtifactIsMissingFailedOrExpired() async throws {
        try await withApp { app in
            let statuses: [PressureArtifactCatalogStatus?] = [nil, .failed, .expired]
            for status in statuses {
                let surfaceCandidate = makeSurfaceCandidate()
                let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
                let payload = makePayload(from: pressureCandidate)
                let idxURL = makeIdxURL(for: pressureCandidate)
                let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
                let dispatcher = WarmJobDispatcherRecorder()
                let service = makeService(
                    remoteChecker: remoteChecker,
                    dispatcher: dispatcher,
                    runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate])
                )

                if let status {
                    try await seedCatalogRow(status: status, payload: payload, lastCheckedAt: nil, on: app.db)
                }

                try await service.probe(on: app, logger: app.logger)

                let row = try #require(try await PressureArtifactCatalogModel.find(
                    runTime: payload.runTime,
                    forecastHour: payload.forecastHour,
                    product: payload.product,
                    fieldSetVersion: payload.fieldSetVersion,
                    on: app.db
                ))

                #expect(dispatcher.dispatches.count == 1)
                #expect(dispatcher.dispatches.first?.queueName == ArcusQueueLane.modelArtifacts.queueName.string)
                #expect(dispatcher.dispatches.first?.payload.runTime == payload.runTime)
                #expect(dispatcher.dispatches.first?.payload.forecastHour == payload.forecastHour)
                #expect(row.status == .pending)
                #expect(row.lastCheckedAt != nil)
                #expect(remoteChecker.requestedURLs == [idxURL.absoluteString])

                try await clearCatalog(on: app.db)
            }
        }
    }

    @Test("probe skips duplicate warm jobs for pending, warming, and ready states")
    func probeSkipsDuplicateWarmJobsForPendingWarmingAndReady() async throws {
        try await withApp { app in
            let statuses: [PressureArtifactCatalogStatus] = [.pending, .warming, .ready]
            for status in statuses {
                let surfaceCandidate = makeSurfaceCandidate()
                let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
                let payload = makePayload(from: pressureCandidate)
                let idxURL = makeIdxURL(for: pressureCandidate)
                let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
                let dispatcher = WarmJobDispatcherRecorder()
                let service = makeService(
                    remoteChecker: remoteChecker,
                    dispatcher: dispatcher,
                    runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate])
                )

                try await seedCatalogRow(status: status, payload: payload, lastCheckedAt: nil, on: app.db)

                try await service.probe(on: app, logger: app.logger)

                let row = try #require(try await PressureArtifactCatalogModel.find(
                    runTime: payload.runTime,
                    forecastHour: payload.forecastHour,
                    product: payload.product,
                    fieldSetVersion: payload.fieldSetVersion,
                    on: app.db
                ))

                #expect(dispatcher.dispatches.isEmpty)
                #expect(row.status == status)
                #expect(remoteChecker.requestedURLs == [idxURL.absoluteString])

                try await clearCatalog(on: app.db)
            }
        }
    }
}

private extension HRRRPressureArtifactProbeServiceTests {
    func withApp(test: (Application) async throws -> Void) async throws {
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

    func makeService<RemoteChecker: HrrrRemoteObjectChecking, Dispatcher: PressureArtifactWarmJobDispatching>(
        remoteChecker: RemoteChecker,
        dispatcher: Dispatcher,
        runResolution: HrrrRunResolution
    ) -> HRRRPressureArtifactProbeService {
        HRRRPressureArtifactProbeService(
            runResolver: FixedHrrrRunResolving(resolution: runResolution),
            remoteObjectChecker: remoteChecker,
            warmJobDispatcher: dispatcher
        )
    }

    func makeSurfaceCandidate() -> HrrrRunCandidate {
        HrrrRunCandidate(
            product: .wrfprsf,
            runTime: makeUTCDate(year: 2026, month: 6, day: 3, hour: 14),
            forecastHour: 8,
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

    func makePayload(from candidate: HrrrRunCandidate) -> PressureArtifactWarmJobPayload {
        PressureArtifactWarmJobPayload(
            runTime: candidate.runTime,
            forecastHour: candidate.forecastHour,
            validTime: candidate.validTime,
            product: candidate.product,
            fieldSetVersion: candidate.fieldSetVersion
        )
    }

    func makeIdxURL(for candidate: HrrrRunCandidate) -> URL {
        HrrrPressureDirectObjectURLBuilder().makeIdxURL(for: candidate)
    }

    func seedCatalogRow(
        status: PressureArtifactCatalogStatus,
        payload: PressureArtifactWarmJobPayload,
        lastCheckedAt: Date?,
        on db: any Database
    ) async throws {
        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: status,
            lastCheckedAt: lastCheckedAt
        )
        try await row.create(on: db)
    }

    func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
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
}

private struct FixedHrrrRunResolving: HrrrRunResolving {
    let resolution: HrrrRunResolution

    func resolveRunCandidates() -> HrrrRunResolution {
        resolution
    }
}

private final class ProbeStubHrrrRemoteObjectChecking: HrrrRemoteObjectChecking, @unchecked Sendable {
    private let availableURLs: [String: Bool]
    private let lock = NSLock()
    private var _requestedURLs: [String] = []

    init(availableURLs: [String: Bool] = [:]) {
        self.availableURLs = availableURLs
    }

    var requestedURLs: [String] {
        lock.withLock { _requestedURLs }
    }

    func probe(url: URL) async -> HrrrRemoteObjectProbeResult {
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

private final class WarmJobDispatcherRecorder: PressureArtifactWarmJobDispatching, @unchecked Sendable {
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

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
