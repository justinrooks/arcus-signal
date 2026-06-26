@testable import App
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor

@Suite("Pressure artifact warm job", .serialized)
struct PressureArtifactWarmJobTests {
    @Test("two concurrent warm jobs do not both build the same artifact")
    func duplicateWarmJobsDoNotBothBuildSameArtifact() async throws {
        try await withApp { app in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub()
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)
            let context = makeQueueContext(app: app)

            async let first = job.dequeue(context, payload)
            async let second = job.dequeue(context, payload)
            try await first
            try await second

            let rows = try await PressureArtifactCatalogModel.query(on: app.db)
                .filter(\.$runTime == payload.runTime)
                .filter(\.$forecastHour == payload.forecastHour)
                .filter(\.$productRaw == payload.product.rawValue)
                .filter(\.$fieldSetVersionRaw == payload.fieldSetVersion.rawValue)
                .all()

            let validationCount = validator.validationCount
            let idxRequestCount = client.idxRequestCount
            let rangeRequestCount = client.rangeRequestCount

            #expect(rows.count == 1)
            #expect(validationCount == 1)
            #expect(idxRequestCount == 1)
            #expect(rangeRequestCount == 5)
        }
    }

    @Test("successful warm marks the catalog row ready and stores path and byte size")
    func successfulWarmMarksCatalogRowReadyAndStoresArtifactPathAndByteSize() async throws {
        try await withApp { app in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub()
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            try await job.dequeue(makeQueueContext(app: app), payload)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            let validationCount = validator.validationCount

            #expect(row.status == .ready)
            #expect(row.localPath?.contains("subset.grib2") == true)
            #expect(row.byteSize == 20)
            #expect(row.source == .aws)
            #expect(row.errorSummary == nil)
            #expect(validationCount == 1)
        }
    }

    @Test("failed warm marks the catalog row failed and stores an error summary")
    func failedWarmMarksTheCatalogRowFailedAndStoresErrorSummary() async throws {
        try await withApp { app in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(error: PressureArtifactWarmValidatorStubError.failedValidation)
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            await #expect(throws: PressureArtifactWarmValidatorStubError.self) {
                try await job.dequeue(makeQueueContext(app: app), payload)
            }

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(row.status == .failed)
            #expect(row.errorSummary?.contains("failedValidation") == true)
            #expect(row.localPath == nil)
            #expect(row.byteSize == nil)
        }
    }

    @Test("ready artifact is skipped without rebuilding")
    func readyArtifactIsSkippedWithoutRebuilding() async throws {
        try await withApp { app in
            let payload = makePayload()
            try await seedCatalogRow(status: .ready, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient()
            let validator = PressureArtifactWarmValidatorStub()
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            try await job.dequeue(makeQueueContext(app: app), payload)

            let idxRequestCount = client.idxRequestCount
            let rangeRequestCount = client.rangeRequestCount
            let validationCount = validator.validationCount

            #expect(idxRequestCount == 0)
            #expect(rangeRequestCount == 0)
            #expect(validationCount == 0)
        }
    }

    @Test("warming artifact is skipped without rebuilding")
    func warmingArtifactIsSkippedWithoutRebuilding() async throws {
        try await withApp { app in
            let payload = makePayload()
            try await seedCatalogRow(status: .warming, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient()
            let validator = PressureArtifactWarmValidatorStub()
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            try await job.dequeue(makeQueueContext(app: app), payload)

            let idxRequestCount = client.idxRequestCount
            let rangeRequestCount = client.rangeRequestCount
            let validationCount = validator.validationCount

            #expect(idxRequestCount == 0)
            #expect(rangeRequestCount == 0)
            #expect(validationCount == 0)
        }
    }

    @Test("default selector includes the expanded pressure ladder and excludes shallow legacy levels")
    func defaultSelectorIncludesExpandedPressureLadderAndExcludesShallowLegacyLevels() {
        let result = HrrrPressureProfileMessageSelector().select(inventory: HrrrPressureIdxInventory.parse(""))
        let requested = result.requestedLevels.map(\.pressureMb)

        #expect(requested.contains(975))
        #expect(requested.contains(100))
        #expect(requested.contains(900))
        #expect(requested.contains(800))
        #expect(requested.contains(700))
        #expect(requested.contains(600))
        #expect(requested.contains(500))
        #expect(requested.contains(400))
        #expect(requested.contains(300))
        #expect(requested.contains(250))
        #expect(requested.contains(200))
        #expect(requested.contains(150))
        #expect(requested.contains(125))
        #expect(requested.contains(100))
        #expect(requested.contains(90) == false)
        #expect(requested.contains(80) == false)
        #expect(requested.contains(70) == false)
        #expect(requested.contains(60) == false)
        #expect(requested.contains(50) == false)
    }

    @Test("validation failure does not mark the artifact ready")
    func validationFailureDoesNotMarkTheArtifactReady() async throws {
        try await withApp { app in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(error: PressureArtifactWarmValidatorStubError.failedValidation)
            let service = PressureArtifactWarmingService(
                httpClient: client,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            await #expect(throws: PressureArtifactWarmValidatorStubError.self) {
                try await job.dequeue(makeQueueContext(app: app), payload)
            }

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(row.status == .failed)
            #expect(row.errorSummary?.contains("failedValidation") == true)
            #expect(row.status != .ready)
        }
    }
}

private extension PressureArtifactWarmJobTests {
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
        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: status
        )
        try await row.create(on: db)
    }

    func makeQueueContext(app: Application) -> QueueContext {
        QueueContext(
            queueName: QueueName(string: "test-pressure-warm"),
            configuration: app.queues.configuration,
            application: app,
            logger: app.logger,
            on: app.eventLoopGroup.any()
        )
    }

    func makePayload() -> PressureArtifactWarmJobPayload {
        PressureArtifactWarmJobPayload(
            runTime: makeDate(year: 2026, month: 6, day: 3, hour: 13),
            forecastHour: 9,
            validTime: makeDate(year: 2026, month: 6, day: 3, hour: 22),
            product: .wrfprsf,
            fieldSetVersion: .tornadoPressureV2
        )
    }

    func makeSourceURLs(for payload: PressureArtifactWarmJobPayload) -> (idx: URL, grib: URL) {
        let candidate = HrrrRunCandidate(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            fieldSetVersion: payload.fieldSetVersion
        )
        let builder = HrrrPressureDirectObjectURLBuilder()
        return (
            idx: builder.makeIdxURL(for: candidate),
            grib: builder.makeGribURL(for: candidate)
        )
    }

    func makeDate(
        year: Int = 2026,
        month: Int = 6,
        day: Int = 3,
        hour: Int = 13,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date ?? .now
    }

    func testRootURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pressure-artifact-warm-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func makeInventoryText() -> String {
        """
        1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
        2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
        3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
        4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
        5:16:d=2026060313:VGRD:1000 mb:9 hour fcst:
        """
    }

    func makeRangeResponses(for payload: PressureArtifactWarmJobPayload) -> [String: HTTPResponse] {
        let sourceURLs = makeSourceURLs(for: payload)
        let inventory = HrrrPressureIdxInventory.parse(makeInventoryText())
        let selection = HrrrPressureProfileMessageSelector(preferredLevels: [.mb1000]).select(inventory: inventory)
        let plan = HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)

        return Dictionary(uniqueKeysWithValues: zip(plan.ranges, [
            Data("hgt-".utf8),
            Data("tmp-".utf8),
            Data("dpt-".utf8),
            Data("ugrd".utf8),
            Data("vgrd".utf8)
        ]).map { range, payload in
            let contentRange = range.closedRange.map { "bytes \($0.lowerBound)-\($0.upperBound)/20" } ?? "bytes 16-19/20"
            return (
                sourceURLs.grib.absoluteString + "|" + range.httpRangeHeaderValue,
                HTTPResponse(
                    status: 206,
                    headers: [
                        "Content-Type": "application/octet-stream",
                        "Content-Range": contentRange
                    ],
                    data: payload
                )
            )
        })
    }

    var serviceRetentionSeconds: TimeInterval { 12 * 60 * 60 }
    var serviceMaximumByteCount: Int { 1024 }
}

private final class PressureArtifactWarmStubHTTPClient: App.HTTPClient, @unchecked Sendable {
    private let idxResponses: [String: Data]
    private let rangeResponses: [String: HTTPResponse]
    private let lock = NSLock()
    private var _idxRequestCount = 0
    private var _rangeRequestCount = 0

    init(
        idxResponses: [String: Data] = [:],
        rangeResponses: [String: HTTPResponse] = [:]
    ) {
        self.idxResponses = idxResponses
        self.rangeResponses = rangeResponses
    }

    var idxRequestCount: Int {
        lock.withLock { _idxRequestCount }
    }

    var rangeRequestCount: Int {
        lock.withLock { _rangeRequestCount }
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        if headers["Range"] == nil {
            lock.withLock { _idxRequestCount += 1 }
            guard let data = idxResponses[url.absoluteString] else {
                throw URLError(.badServerResponse)
            }

            return HTTPResponse(
                status: 200,
                headers: ["Content-Type": "text/plain; charset=utf-8"],
                data: data
            )
        }

        lock.withLock { _rangeRequestCount += 1 }
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

private enum PressureArtifactWarmValidatorStubError: Error, CustomStringConvertible {
    case failedValidation

    var description: String {
        switch self {
        case .failedValidation:
            return "failedValidation"
        }
    }
}

private final class PressureArtifactWarmValidatorStub: PressureArtifactValidating, @unchecked Sendable {
    private let error: (any Error)?
    private let lock = NSLock()
    private var _validationCount = 0

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var validationCount: Int {
        lock.withLock { _validationCount }
    }

    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult {
        lock.withLock { _validationCount += 1 }

        if let error {
            throw error
        }

        return PressureArtifactValidationResult(stdoutLineCount: 1)
    }
}

private struct FixedStormSetupDateProvider: StormSetupDateProviding {
    let nowDate: Date

    func now() -> Date {
        nowDate
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
