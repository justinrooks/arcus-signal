@testable import App
import FluentSQL
import Foundation
import Queues
import Testing
import Vapor

@Suite("Pressure artifact warm job", .serialized)
struct PressureArtifactWarmJobTests {
    @Test("pressure payload requests wrfprsf source URLs")
    func pressurePayloadRequestsPressureProductSourceURLs() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount()),
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )

            try await service.warm(payload: payload, on: app, logger: app.logger)

            #expect(client.requestedURLs.isEmpty == false)
            #expect(client.requestedURLs.allSatisfy { $0.contains(".wrfprsf") })
        }
    }

    @Test("two concurrent warm jobs do not both build the same artifact")
    func duplicateWarmJobsDoNotBothBuildSameArtifact() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let expectedLineCount = makeExpectedValidationLineCount()
            let validator = PressureArtifactWarmValidatorStub(lineCount: expectedLineCount)
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
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
            #expect(rangeRequestCount == expectedLineCount)
        }
    }

    @Test("full expanded pressure contract succeeds")
    func fullExpandedPressureContractSucceeds() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)
            let expectedLineCount = makeExpectedValidationLineCount()

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: expectedLineCount)
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
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
            #expect(row.byteSize == Int64(expectedLineCount * 4))
            #expect(row.source == .aws)
            #expect(row.errorSummary == nil)
            #expect(validationCount == 1)
        }
    }

    @Test("failed warm marks the catalog row failed and stores an error summary")
    func failedWarmMarksTheCatalogRowFailedAndStoresErrorSummary() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)
            let expectedLineCount = makeExpectedValidationLineCount()

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(
                error: PressureArtifactWarmValidatorStubError.failedValidation,
                lineCount: expectedLineCount
            )
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
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

    @Test("warm cancellation leaves the catalog claim available for recovery")
    func warmCancellationLeavesTheCatalogClaimAvailableForRecovery() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(error: CancellationError(), lineCount: makeExpectedValidationLineCount())
            let cacheRoot = testRootURL()
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: cacheRoot,
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount,
                recoveryTimeoutSeconds: 1_800
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            await #expect(throws: CancellationError.self) {
                try await job.dequeue(makeQueueContext(app: app), payload)
            }

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            let cachedKey = try HrrrPressureSubsetGribCacheKey(
                sourceMetadata: makeSourceMetadata(for: payload),
                byteRangePlan: try makeByteRangePlan()
            )

            #expect(row.status == .warming)
            #expect(row.claimToken != nil)
            #expect(row.leaseExpiresAt != nil)
            #expect(row.localPath == nil)
            #expect(row.byteSize == nil)
            #expect(row.errorSummary == nil)
            #expect(client.idxRequestCount == 1)
            #expect(client.rangeRequestCount == makeExpectedValidationLineCount())
            #expect(validator.validationCount == 1)
            #expect(FileManager.default.fileExists(atPath: cachedKey.subsetFileURL(rootURL: cacheRoot).path))
            #expect(FileManager.default.fileExists(atPath: cachedKey.metadataFileURL(rootURL: cacheRoot).path))
        }
    }

    @Test("ready artifact is skipped without rebuilding")
    func readyArtifactIsSkippedWithoutRebuilding() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            try await seedCatalogRow(status: .ready, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient()
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
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
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            try await seedCatalogRow(status: .warming, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient()
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
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

    @Test("expired rows with active cleanup claims are skipped without rebuilding")
    func expiredRowsWithActiveCleanupClaimsAreSkippedWithoutRebuilding() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            let claimToken = UUID()
            try await seedCatalogRow(
                status: .expired,
                payload: payload,
                claimToken: claimToken,
                leaseExpiresAt: makeDate(year: 2026, month: 6, day: 30, hour: 13, minute: 30),
                on: app.db
            )

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )

            try await service.warm(payload: payload, on: app, logger: app.logger)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(client.idxRequestCount == 0)
            #expect(client.rangeRequestCount == 0)
            #expect(validator.validationCount == 0)
            #expect(row.status == .expired)
            #expect(row.claimToken == claimToken)
            #expect(row.leaseExpiresAt != nil)
        }
    }

    @Test("warm claim stores a token and lease")
    func warmClaimStoresATokenAndLease() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount,
                recoveryTimeoutSeconds: 1_800
            )
            let claimToken = UUID()
            let row = try #require(try await service.claimCatalogRow(
                for: payload,
                claimToken: claimToken,
                on: app.db
            ))

            #expect(row.status == .warming)
            #expect(row.claimToken != nil)
            #expect(row.leaseExpiresAt != nil)
        }
    }

    @Test("successful owner clears claim metadata and marks ready")
    func successfulOwnerClearsClaimMetadataAndMarksReady() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount,
                recoveryTimeoutSeconds: 1_800
            )

            try await service.warm(payload: payload, on: app, logger: app.logger)

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(row.status == .ready)
            #expect(row.claimToken == nil)
            #expect(row.leaseExpiresAt == nil)
        }
    }

    @Test("failed owner clears claim metadata and marks failed")
    func failedOwnerClearsClaimMetadataAndMarksFailed() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(
                error: PressureArtifactWarmValidatorStubError.failedValidation,
                lineCount: makeExpectedValidationLineCount()
            )
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount,
                recoveryTimeoutSeconds: 1_800
            )

            await #expect(throws: PressureArtifactWarmValidatorStubError.self) {
                try await service.warm(payload: payload, on: app, logger: app.logger)
            }

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(row.status == .failed)
            #expect(row.claimToken == nil)
            #expect(row.leaseExpiresAt == nil)
        }
    }

    @Test("an old token cannot mark ready after a newer claim exists")
    func oldTokenCannotMarkReadyAfterANewerClaimExists() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount,
                recoveryTimeoutSeconds: 1_800
            )

            let claimToken = UUID()
            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))
            row.status = .warming
            row.claimToken = UUID()
            row.leaseExpiresAt = makeDate().addingTimeInterval(1_800)
            try await row.update(on: app.db)

            let result = try await service.markReady(
                payload: payload,
                claimToken: claimToken,
                localPath: "/tmp/pressure-artifact.grib2",
                byteSize: 99,
                on: app.db
            )

            #expect(result == false)
            let refetched = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(refetched.status == .warming)
            #expect(refetched.claimToken != nil)
            #expect(refetched.leaseExpiresAt != nil)
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

    @Test("validation line-count mismatch marks the catalog row failed")
    func validationLineCountMismatchMarksTheCatalogRowFailed() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)
            let expectedLineCount = makeExpectedValidationLineCount()

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: expectedLineCount - 1)
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            await #expect(throws: PressureArtifactWarmingError.self) {
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
            #expect(row.errorSummary?.contains("expected \(expectedLineCount)") == true)
            #expect(row.errorSummary?.contains("returned \(expectedLineCount - 1) messages") == true)
            #expect(row.status != .ready)
        }
    }

    @Test("incomplete pressure inventory fails before any range download")
    func incompletePressureInventoryFailsBeforeAnyRangeDownload() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeIncompleteInventoryText().utf8)]
            )
            let validator = PressureArtifactWarmValidatorStub(lineCount: makeExpectedValidationLineCount())
            let service = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: validator,
                cacheRootURL: testRootURL(),
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )
            let job = PressureArtifactWarmJob(warmingService: service)

            await #expect(throws: PressureArtifactWarmingError.self) {
                try await job.dequeue(makeQueueContext(app: app), payload)
            }

            let row = try #require(try await PressureArtifactCatalogModel.find(
                runTime: payload.runTime,
                forecastHour: payload.forecastHour,
                product: payload.product,
                fieldSetVersion: payload.fieldSetVersion,
                on: app.db
            ))

            #expect(client.idxRequestCount == 1)
            #expect(client.rangeRequestCount == 0)
            #expect(row.status == .failed)
            #expect(row.status != .ready)
            #expect(row.errorSummary?.contains("selection is incomplete") == true)
        }
    }

    @Test("validation failure removes the failed cache and the next warm redownloads")
    func validationFailureRemovesFailedCacheAndNextWarmRedownloads() async throws {
        try await withApp { app, blockingWorkExecutor in
            let payload = makePayload()
            let sourceURLs = makeSourceURLs(for: payload)
            try await seedCatalogRow(status: .pending, payload: payload, on: app.db)
            let expectedLineCount = makeExpectedValidationLineCount()
            let cacheRoot = testRootURL()

            let client = PressureArtifactWarmStubHTTPClient(
                idxResponses: [sourceURLs.idx.absoluteString: Data(makeCompleteInventoryText().utf8)],
                rangeResponses: makeRangeResponses(for: payload)
            )

            let failedService = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: PressureArtifactWarmValidatorStub(lineCount: expectedLineCount - 1),
                cacheRootURL: cacheRoot,
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate()),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )

            await #expect(throws: PressureArtifactWarmingError.self) {
                try await failedService.warm(payload: payload, on: app, logger: app.logger)
            }

            let cachedKey = try HrrrPressureSubsetGribCacheKey(
                sourceMetadata: makeSourceMetadata(for: payload),
                byteRangePlan: makeByteRangePlan()
            )
            #expect(FileManager.default.fileExists(atPath: cachedKey.subsetFileURL(rootURL: cacheRoot).path) == false)
            #expect(FileManager.default.fileExists(atPath: cachedKey.metadataFileURL(rootURL: cacheRoot).path) == false)

            let retryService = PressureArtifactWarmingService(
                httpClient: client,
                blockingWorkExecutor: blockingWorkExecutor,
                validator: PressureArtifactWarmValidatorStub(lineCount: expectedLineCount),
                cacheRootURL: cacheRoot,
                dateProvider: FixedStormSetupDateProvider(nowDate: makeDate(hour: 14)),
                retentionDuration: serviceRetentionSeconds,
                maximumByteCount: serviceMaximumByteCount
            )

            try await retryService.warm(payload: payload, on: app, logger: app.logger)

            #expect(client.rangeRequestCount == expectedLineCount * 2)
        }
    }
}

private extension PressureArtifactWarmJobTests {
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
        claimToken: UUID? = nil,
        leaseExpiresAt: Date? = nil,
        on db: any Database
    ) async throws {
        let row = PressureArtifactCatalogModel(
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            product: payload.product,
            fieldSetVersion: payload.fieldSetVersion,
            status: status,
            claimToken: claimToken,
            leaseExpiresAt: leaseExpiresAt
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
            product: payload.product,
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

    func makeIncompleteInventoryText() -> String {
        """
        1:0:d=2026060313:HGT:1000 mb:9 hour fcst:
        2:4:d=2026060313:TMP:1000 mb:9 hour fcst:
        3:8:d=2026060313:DPT:1000 mb:9 hour fcst:
        4:12:d=2026060313:UGRD:1000 mb:9 hour fcst:
        """
    }

    func makeExpectedValidationLineCount() -> Int {
        HrrrPressureProfileMessageSelector()
            .select(inventory: HrrrPressureIdxInventory.parse(makeCompleteInventoryText()))
            .selectedMessages
            .count
    }

    func makeByteRangePlan() throws -> HrrrGribByteRangePlan {
        let inventory = HrrrPressureIdxInventory.parse(makeCompleteInventoryText())
        let selection = HrrrPressureProfileMessageSelector().select(inventory: inventory)
        return HrrrGribByteRangePlanner().plan(inventory: inventory, selectedMessages: selection.selectedMessages)
    }

    func makeSourceMetadata(for payload: PressureArtifactWarmJobPayload) -> StormSetupSourceMetadata {
        let sourceURLs = makeSourceURLs(for: payload)
        return StormSetupSourceMetadata(
            sourceKind: .directObject,
            model: .hrrr,
            product: payload.product,
            domain: .conus,
            runTime: payload.runTime,
            forecastHour: payload.forecastHour,
            validTime: payload.validTime,
            fieldSetVersion: payload.fieldSetVersion,
            primaryDownloadURL: sourceURLs.grib,
            idxURL: sourceURLs.idx
        )
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

    var serviceRetentionSeconds: TimeInterval { 12 * 60 * 60 }
    var serviceMaximumByteCount: Int { 1024 }
}

private final class PressureArtifactWarmStubHTTPClient: App.HTTPClient, @unchecked Sendable {
    private let idxResponses: [String: Data]
    private let rangeResponses: [String: HTTPResponse]
    private let lock = NSLock()
    private var _idxRequestCount = 0
    private var _rangeRequestCount = 0
    private var _requestedURLs: [String] = []

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

    var requestedURLs: [String] {
        lock.withLock { _requestedURLs }
    }

    func get(_ url: URL, headers: [String : String]) async throws -> HTTPResponse {
        lock.withLock { _requestedURLs.append(url.absoluteString) }

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
    private let lineCount: Int
    private let lock = NSLock()
    private var _validationCount = 0

    init(error: (any Error)? = nil, lineCount: Int) {
        self.error = error
        self.lineCount = lineCount
    }

    var validationCount: Int {
        lock.withLock { _validationCount }
    }

    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult {
        lock.withLock { _validationCount += 1 }

        if let error {
            throw error
        }

        return PressureArtifactValidationResult(stdoutLineCount: lineCount)
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
