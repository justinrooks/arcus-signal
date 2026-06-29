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
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
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
                    runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                    now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
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

    @Test("recent pending rows remain skipped while stale pending rows are redispatched once")
    func recentPendingRowsRemainSkippedWhileStalePendingRowsAreRedispatchedOnce() async throws {
        try await withApp { app in
            let surfaceCandidate = makeSurfaceCandidate()
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let idxURL = makeIdxURL(for: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
            let dispatcher = WarmJobDispatcherRecorder()
            let service = makeService(
                remoteChecker: remoteChecker,
                dispatcher: dispatcher,
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                recoveryTimeoutSeconds: 1_800
            )

            try await seedCatalogRow(
                status: .pending,
                payload: payload,
                lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 45),
                on: app.db
            )

            try await service.probe(on: app, logger: app.logger)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(dispatcher.dispatches.isEmpty)
            #expect(row.status == .pending)
            #expect(remoteChecker.requestedURLs == [idxURL.absoluteString])
        }
    }

    @Test("expired warming leases are reclaimed and redispatched once while active leases stay skipped")
    func expiredWarmingLeasesAreReclaimedAndRedispatchedOnceWhileActiveLeasesStaySkipped() async throws {
        try await withApp { app in
            let statuses: [(status: PressureArtifactCatalogStatus, leaseExpiresAt: Date?, expectedDispatches: Int)] = [
                (.warming, makeUTCDate(year: 2026, month: 6, day: 30, hour: 13, minute: 15), 0),
                (.warming, makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 30), 1)
            ]

            for item in statuses {
                let surfaceCandidate = makeSurfaceCandidate()
                let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
                let payload = makePayload(from: pressureCandidate)
                let idxURL = makeIdxURL(for: pressureCandidate)
                let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
                let dispatcher = WarmJobDispatcherRecorder()
                let service = makeService(
                    remoteChecker: remoteChecker,
                    dispatcher: dispatcher,
                    runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                    now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                    recoveryTimeoutSeconds: 1_800
                )

                try await seedCatalogRow(
                    status: item.status,
                    payload: payload,
                    lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 0),
                    leaseExpiresAt: item.leaseExpiresAt,
                    on: app.db
                )

                try await service.probe(on: app, logger: app.logger)

                let row = try #require(try await PressureArtifactCatalogModel.find(
                    runTime: payload.runTime,
                    forecastHour: payload.forecastHour,
                    product: payload.product,
                    fieldSetVersion: payload.fieldSetVersion,
                    on: app.db
                ))

                #expect(dispatcher.dispatches.count == item.expectedDispatches)
                if item.expectedDispatches == 0 {
                    #expect(row.status == .warming)
                } else {
                    #expect(row.status == .pending)
                    #expect(row.claimToken == nil)
                    #expect(row.leaseExpiresAt == nil)
                }
                try await clearCatalog(on: app.db)
            }
        }
    }

    @Test("ready rows with unusable local files are reset to pending and redispatched")
    func readyRowsWithUnusableLocalFilesAreResetToPendingAndRedispatched() async throws {
        try await withApp { app in
            let surfaceCandidate = makeSurfaceCandidate()
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let idxURL = makeIdxURL(for: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
            let dispatcher = WarmJobDispatcherRecorder()
            let service = makeService(
                remoteChecker: remoteChecker,
                dispatcher: dispatcher,
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                recoveryTimeoutSeconds: 1_800
            )
            let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).grib2")
            try await seedCatalogRow(
                status: .ready,
                payload: payload,
                localPath: missingPath.path,
                byteSize: 9,
                on: app.db
            )

            try await service.probe(on: app, logger: app.logger)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(dispatcher.dispatches.count == 1)
            #expect(row.status == .pending)
            #expect(row.localPath == nil)
            #expect(row.byteSize == nil)
            #expect(row.claimToken == nil)
            #expect(row.leaseExpiresAt == nil)
        }
    }

    @Test("concurrent probes reclaim or repair at most once")
    func concurrentProbesReclaimOrRepairAtMostOnce() async throws {
        try await withApp { app in
            let surfaceCandidate = makeSurfaceCandidate()
            let pressureCandidate = makePressureCandidate(from: surfaceCandidate)
            let payload = makePayload(from: pressureCandidate)
            let idxURL = makeIdxURL(for: pressureCandidate)
            let remoteChecker = ProbeStubHrrrRemoteObjectChecking(availableURLs: [idxURL.absoluteString: true])
            let dispatcher = WarmJobDispatcherRecorder()
            let service = makeService(
                remoteChecker: remoteChecker,
                dispatcher: dispatcher,
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13),
                recoveryTimeoutSeconds: 1_800
            )
            let missingPath = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).grib2")
            try await seedCatalogRow(
                status: .ready,
                payload: payload,
                localPath: missingPath.path,
                byteSize: 9,
                on: app.db
            )

            async let first = service.probe(on: app, logger: app.logger)
            async let second = service.probe(on: app, logger: app.logger)
            try await first
            try await second

            let rows = try await PressureArtifactCatalogModel.query(on: app.db)
                .filter(\.$runTime == payload.runTime)
                .filter(\.$forecastHour == payload.forecastHour)
                .filter(\.$productRaw == payload.product.rawValue)
                .filter(\.$fieldSetVersionRaw == payload.fieldSetVersion.rawValue)
                .all()

            #expect(dispatcher.dispatches.count == 1)
            #expect(rows.count == 1)
            #expect(rows.first?.status == .pending)
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
                runResolution: HrrrRunResolution(targetValidTime: surfaceCandidate.validTime, candidates: [surfaceCandidate]),
                now: makeUTCDate(year: 2026, month: 6, day: 3, hour: 13)
            )

                switch status {
                case .pending:
                    try await seedCatalogRow(
                        status: .pending,
                        payload: payload,
                        lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 45),
                        on: app.db
                    )
                case .warming:
                    try await seedCatalogRow(
                        status: .warming,
                        payload: payload,
                        lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 0),
                        leaseExpiresAt: makeUTCDate(year: 2026, month: 6, day: 30, hour: 13, minute: 30),
                        on: app.db
                    )
                case .ready:
                    let readyURL = FileManager.default.temporaryDirectory.appendingPathComponent("ready-\(UUID().uuidString).grib2")
                    FileManager.default.createFile(atPath: readyURL.path, contents: Data("ready".utf8))
                    try await seedCatalogRow(
                        status: .ready,
                        payload: payload,
                        lastCheckedAt: makeUTCDate(year: 2026, month: 6, day: 3, hour: 12, minute: 0),
                        localPath: readyURL.path,
                        byteSize: 5,
                        on: app.db
                    )
                default:
                    break
                }

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

    func makeService<RemoteChecker: HrrrRemoteObjectChecking, Dispatcher: PressureArtifactWarmJobDispatching>(
        remoteChecker: RemoteChecker,
        dispatcher: Dispatcher,
        runResolution: HrrrRunResolution,
        now: Date,
        recoveryTimeoutSeconds: TimeInterval = 1_800
    ) -> HRRRPressureArtifactProbeService {
        HRRRPressureArtifactProbeService(
            runResolver: FixedHrrrRunResolving(resolution: runResolution),
            remoteObjectChecker: remoteChecker,
            warmJobDispatcher: dispatcher,
            dateProvider: FixedStormSetupDateProvider(nowDate: now),
            recoveryTimeoutSeconds: recoveryTimeoutSeconds
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
        lastCheckedAt: Date? = nil,
        leaseExpiresAt: Date? = nil,
        localPath: String? = nil,
        byteSize: Int64? = nil,
        on db: any Database
    ) async throws {
        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: status,
            localPath: localPath,
            byteSize: byteSize,
            lastCheckedAt: lastCheckedAt
        )
        row.leaseExpiresAt = leaseExpiresAt
        try await row.create(on: db)
    }

    func clearCatalog(on db: any Database) async throws {
        guard let sql = db as? any SQLDatabase else {
            throw Abort(.internalServerError, reason: "Database is not SQLDatabase")
        }

        try await sql.raw("DELETE FROM pressure_artifact_catalog;").run()
    }

    private struct FixedStormSetupDateProvider: StormSetupDateProviding {
        let nowDate: Date

        func now() -> Date {
            nowDate
        }
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
