@testable import App
import Queues
import Redis
import Testing
import Vapor

@Suite("Model-artifact queue recovery", .serialized)
struct ModelArtifactQueueRecoveryTests {
    @Test("known abandoned jobs are planned back to waiting")
    func knownAbandonedJobIsPlannedBackToWaiting() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(
                named: PressureArtifactWarmJob.name,
                with: jobIdentifier,
                in: queue
            )
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.waitingJobIdentifiers.isEmpty)
            #expect(snapshot.processingEntries == [
                .job(jobIdentifier: jobIdentifier, jobDataState: .named(PressureArtifactWarmJob.name))
            ])
            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .returnToWaiting(jobIdentifier)
            ])
        }
    }

    @Test("missing job data remains in processing for investigation")
    func missingJobDataIsPreserved() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.processingEntries == [
                .job(jobIdentifier: jobIdentifier, jobDataState: .missing)
            ])
            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .preserveMissingJobData(jobIdentifier)
            ])
        }
    }

    @Test("unknown jobs remain in processing for investigation")
    func unknownJobIsPreserved() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(named: "UnrecognizedModelArtifactJob", with: jobIdentifier, in: queue)
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .preserveUnknownJob(jobIdentifier, jobName: "UnrecognizedModelArtifactJob")
            ])
        }
    }

    @Test("malformed job data is preserved while valid jobs remain recoverable")
    func malformedJobDataDoesNotHideKnownAbandonedJob() async throws {
        let knownJobIdentifier = JobIdentifier()
        let malformedJobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [knownJobIdentifier, malformedJobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(
                named: CleanupPressureArtifactsJob.name,
                with: knownJobIdentifier,
                in: queue
            )
            try await storeMalformedJobData(for: malformedJobIdentifier, using: redis)
            try await addToProcessing(knownJobIdentifier, for: queue, using: redis)
            try await addToProcessing(malformedJobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .preserveMalformedJobData(malformedJobIdentifier),
                .returnToWaiting(knownJobIdentifier)
            ])
        }
    }

    @Test("malformed processing identifiers are preserved while valid jobs remain recoverable")
    func malformedIdentifierDoesNotHideKnownAbandonedJob() async throws {
        let knownJobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [knownJobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(
                named: CleanupPressureArtifactsJob.name,
                with: knownJobIdentifier,
                in: queue
            )
            try await addToProcessing(knownJobIdentifier, for: queue, using: redis)
            try await addMalformedIdentifierToProcessing(for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .preserveMalformedIdentifier,
                .returnToWaiting(knownJobIdentifier)
            ])
        }
    }

    @Test("duplicate processing membership yields one waiting transition")
    func duplicateProcessingMembershipIsDeduplicated() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(
                named: PressureArtifactFailureCompletionJob.name,
                with: jobIdentifier,
                in: queue
            )
            try await addToProcessing(jobIdentifier, for: queue, using: redis)
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.processingEntries.count == 2)
            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .returnToWaiting(jobIdentifier)
            ])
        }
    }

    @Test("already-waiting known jobs are not added to waiting again")
    func alreadyWaitingKnownJobOnlyRemovesProcessingMembership() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(
                named: PressureArtifactWarmJob.name,
                with: jobIdentifier,
                in: queue
            )
            _ = try await redis.lpush(jobIdentifier.string, into: RedisKey(queue.key)).get()
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let snapshot = try await recoveryStore.snapshot()

            #expect(snapshot.waitingJobIdentifiers == [jobIdentifier])
            #expect(snapshot.plan(knownJobNames: ModelArtifactQueueRecoveryContract.knownJobNames).actions == [
                .removeProcessingDuplicate(jobIdentifier)
            ])
        }
    }

    @Test("startup recovery returns every registered job exactly once without changing job data or other lanes")
    func recoveryReturnsKnownJobsAtomicallyAndIdempotently() async throws {
        let jobs = [
            (JobIdentifier(), PressureArtifactWarmJob.name, [UInt8]("warm".utf8)),
            (JobIdentifier(), PressureArtifactFailureCompletionJob.name, [UInt8]("completion".utf8)),
            (JobIdentifier(), CleanupPressureArtifactsJob.name, [UInt8]("cleanup".utf8))
        ]

        try await withUniqueQueue(jobIdentifiers: jobs.map(\.0)) { recoveryStore, queue, redis in
            for (identifier, jobName, payload) in jobs {
                try await storeJob(named: jobName, payload: payload, with: identifier, in: queue)
                try await addToProcessing(identifier, for: queue, using: redis)
            }

            let unrelatedWaitingKey = RedisKey("\(queue.key)-unrelated-waiting")
            let unrelatedProcessingKey = RedisKey("\(queue.key)-unrelated-processing")
            _ = try await redis.lpush("unrelated-waiting", into: unrelatedWaitingKey).get()
            _ = try await redis.lpush("unrelated-processing", into: unrelatedProcessingKey).get()

            let firstSummary = try await recoveryStore.recoverKnownJobs()
            let firstSnapshot = try await recoveryStore.snapshot()

            #expect(firstSummary.inspectedEntryCount == jobs.count)
            #expect(Set(firstSummary.returnedJobIdentifiers) == Set(jobs.map(\.0.string)))
            #expect(firstSummary.alreadyWaitingJobIdentifiers.isEmpty)
            #expect(firstSummary.removedProcessingEntryCount == jobs.count)
            #expect(Set(firstSnapshot.waitingJobIdentifiers) == Set(jobs.map(\.0)))
            #expect(firstSnapshot.processingEntries.isEmpty)

            for (identifier, jobName, payload) in jobs {
                let stored = try await queue.get(identifier).get()
                #expect(stored.jobName == jobName)
                #expect(stored.payload == payload)
            }

            let unrelatedWaiting = try await redis
                .lrange(from: unrelatedWaitingKey, firstIndex: 0, lastIndex: -1, as: String.self)
                .get()
            let unrelatedProcessing = try await redis
                .lrange(from: unrelatedProcessingKey, firstIndex: 0, lastIndex: -1, as: String.self)
                .get()
            #expect(unrelatedWaiting == ["unrelated-waiting"])
            #expect(unrelatedProcessing == ["unrelated-processing"])

            let secondSummary = try await recoveryStore.recoverKnownJobs()
            let secondSnapshot = try await recoveryStore.snapshot()
            #expect(secondSummary == .empty)
            #expect(secondSnapshot == firstSnapshot)
        }
    }

    @Test("recovery preserves and reports unknown, missing, and malformed entries")
    func recoveryPreservesUntrustworthyEntries() async throws {
        let knownIdentifier = JobIdentifier()
        let unknownIdentifier = JobIdentifier()
        let missingIdentifier = JobIdentifier()
        let malformedDataIdentifier = JobIdentifier()
        let identifiers = [knownIdentifier, unknownIdentifier, missingIdentifier, malformedDataIdentifier]

        try await withUniqueQueue(jobIdentifiers: identifiers) { recoveryStore, queue, redis in
            try await storeJob(named: PressureArtifactWarmJob.name, with: knownIdentifier, in: queue)
            try await storeJob(named: "UnrecognizedModelArtifactJob", with: unknownIdentifier, in: queue)
            try await storeMalformedJobData(for: malformedDataIdentifier, using: redis)
            for identifier in identifiers {
                try await addToProcessing(identifier, for: queue, using: redis)
            }
            try await addMalformedIdentifierToProcessing(for: queue, using: redis)

            let summary = try await recoveryStore.recoverKnownJobs()
            let snapshot = try await recoveryStore.snapshot()

            #expect(summary.inspectedEntryCount == 5)
            #expect(summary.returnedJobIdentifiers == [knownIdentifier.string])
            #expect(summary.removedProcessingEntryCount == 1)
            #expect(summary.preservedUnknownJobCount == 1)
            #expect(summary.preservedMissingJobDataCount == 1)
            #expect(summary.preservedMalformedJobDataCount == 1)
            #expect(summary.preservedMalformedIdentifierCount == 1)
            #expect(snapshot.waitingJobIdentifiers == [knownIdentifier])
            #expect(snapshot.processingEntries.count == 4)
            #expect(snapshot.processingEntries.contains(.malformedIdentifier))
            #expect(snapshot.processingEntries.contains(
                .job(jobIdentifier: unknownIdentifier, jobDataState: .named("UnrecognizedModelArtifactJob"))
            ))
            #expect(snapshot.processingEntries.contains(
                .job(jobIdentifier: missingIdentifier, jobDataState: .missing)
            ))
            #expect(snapshot.processingEntries.contains(
                .job(jobIdentifier: malformedDataIdentifier, jobDataState: .malformed)
            ))
        }
    }

    @Test("structurally malformed registered job data remains in processing")
    func recoveryPreservesStructurallyMalformedRegisteredJob() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            let malformedData = Data("{\"jobName\":\"\(PressureArtifactWarmJob.name)\"}".utf8)
            try await redis
                .set(RedisKey("job:\(jobIdentifier.string)"), to: malformedData)
                .get()
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let firstSummary = try await recoveryStore.recoverKnownJobs()
            let firstSnapshot = try await recoveryStore.snapshot()

            #expect(firstSummary.inspectedEntryCount == 1)
            #expect(firstSummary.returnedJobIdentifiers.isEmpty)
            #expect(firstSummary.preservedMalformedJobDataCount == 1)
            #expect(firstSnapshot.waitingJobIdentifiers.isEmpty)
            #expect(firstSnapshot.processingEntries == [
                .job(jobIdentifier: jobIdentifier, jobDataState: .malformed)
            ])

            let secondSummary = try await recoveryStore.recoverKnownJobs()
            #expect(secondSummary.preservedMalformedJobDataCount == 1)
            #expect(try await recoveryStore.snapshot() == firstSnapshot)
        }
    }

    @Test("object-valued payload remains in processing even when the job name is registered")
    func recoveryPreservesRegisteredJobWithObjectPayload() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            let malformedData = Data(
                "{\"payload\":{},\"maxRetryCount\":0,\"queuedAt\":0,\"jobName\":\"\(PressureArtifactWarmJob.name)\"}".utf8
            )
            try await redis
                .set(RedisKey("job:\(jobIdentifier.string)"), to: malformedData)
                .get()
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let firstSummary = try await recoveryStore.recoverKnownJobs()
            let firstSnapshot = try await recoveryStore.snapshot()

            #expect(firstSummary.inspectedEntryCount == 1)
            #expect(firstSummary.returnedJobIdentifiers.isEmpty)
            #expect(firstSummary.preservedMalformedJobDataCount == 1)
            #expect(firstSnapshot.waitingJobIdentifiers.isEmpty)
            #expect(firstSnapshot.processingEntries == [
                .job(jobIdentifier: jobIdentifier, jobDataState: .malformed)
            ])

            let secondSummary = try await recoveryStore.recoverKnownJobs()
            #expect(secondSummary.preservedMalformedJobDataCount == 1)
            #expect(try await recoveryStore.snapshot() == firstSnapshot)
        }
    }

    @Test("recovery removes duplicate processing membership without duplicating waiting membership")
    func recoveryDoesNotDuplicateAlreadyWaitingJob() async throws {
        let jobIdentifier = JobIdentifier()

        try await withUniqueQueue(jobIdentifiers: [jobIdentifier]) { recoveryStore, queue, redis in
            try await storeJob(named: CleanupPressureArtifactsJob.name, with: jobIdentifier, in: queue)
            _ = try await redis.lpush(jobIdentifier.string, into: RedisKey(queue.key)).get()
            try await addToProcessing(jobIdentifier, for: queue, using: redis)
            try await addToProcessing(jobIdentifier, for: queue, using: redis)

            let summary = try await recoveryStore.recoverKnownJobs()
            let snapshot = try await recoveryStore.snapshot()

            #expect(summary.inspectedEntryCount == 2)
            #expect(summary.returnedJobIdentifiers.isEmpty)
            #expect(summary.alreadyWaitingJobIdentifiers == [jobIdentifier.string])
            #expect(summary.removedProcessingEntryCount == 2)
            #expect(snapshot.waitingJobIdentifiers == [jobIdentifier])
            #expect(snapshot.processingEntries.isEmpty)
            #expect(try await recoveryStore.recoverKnownJobs() == .empty)
        }
    }

    @Test("recovery failure leaves every processing entry untouched")
    func recoveryFailureDoesNotPartiallyMutateQueue() async throws {
        let knownIdentifier = JobIdentifier()
        let invalidStateIdentifier = JobIdentifier()

        try await withUniqueQueue(
            jobIdentifiers: [knownIdentifier, invalidStateIdentifier]
        ) { recoveryStore, queue, redis in
            try await storeJob(named: PressureArtifactWarmJob.name, with: knownIdentifier, in: queue)
            _ = try await redis
                .lpush("wrong Redis type", into: RedisKey("job:\(invalidStateIdentifier.string)"))
                .get()
            try await addToProcessing(invalidStateIdentifier, for: queue, using: redis)
            try await addToProcessing(knownIdentifier, for: queue, using: redis)

            var recoveryFailed = false
            do {
                _ = try await recoveryStore.recoverKnownJobs()
            } catch {
                recoveryFailed = true
            }

            let waiting = try await redis
                .lrange(from: RedisKey(queue.key), firstIndex: 0, lastIndex: -1, as: String.self)
                .get()
            let processing = try await redis
                .lrange(from: RedisKey("\(queue.key)-processing"), firstIndex: 0, lastIndex: -1, as: String.self)
                .get()
            #expect(recoveryFailed)
            #expect(waiting.isEmpty)
            #expect(Set(processing.compactMap { $0 }) == Set([knownIdentifier.string, invalidStateIdentifier.string]))
        }
    }
}

private extension ModelArtifactQueueRecoveryTests {
    func withUniqueQueue(
        jobIdentifiers: [JobIdentifier],
        test: (ModelArtifactQueueRecoveryStore, any Queue, any RedisClient) async throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        let queueName = QueueName(string: "issue-194-\(UUID().uuidString)")

        do {
            try await configure(app, mode: .api)

            let queue = app.queues.queue(queueName)
            guard let redis = queue as? any RedisClient else {
                throw ModelArtifactQueueRecoveryTestError.redisQueueDriverUnavailable
            }

            let recoveryStore = ModelArtifactQueueRecoveryStore(queue: queue, redis: redis)
            try await test(recoveryStore, queue, redis)
            try await deleteTestKeys(for: queue, jobIdentifiers: jobIdentifiers, using: redis)
            try await app.asyncShutdown()
        } catch {
            let queue = app.queues.queue(queueName)
            if let redis = queue as? any RedisClient {
                try? await deleteTestKeys(
                    for: queue,
                    jobIdentifiers: jobIdentifiers,
                    using: redis
                )
            }
            try? await app.asyncShutdown()
            throw error
        }
    }

    func storeJob(
        named jobName: String,
        payload: [UInt8] = [],
        with jobIdentifier: JobIdentifier,
        in queue: any Queue
    ) async throws {
        try await queue.set(
            jobIdentifier,
            to: JobData(
                payload: payload,
                maxRetryCount: 0,
                jobName: jobName,
                delayUntil: nil,
                queuedAt: .now
            )
        ).get()
    }

    func addToProcessing(
        _ jobIdentifier: JobIdentifier,
        for queue: any Queue,
        using redis: any RedisClient
    ) async throws {
        _ = try await redis
            .lpush(jobIdentifier.string, into: RedisKey("\(queue.key)-processing"))
            .get()
    }

    func storeMalformedJobData(
        for jobIdentifier: JobIdentifier,
        using redis: any RedisClient
    ) async throws {
        try await redis
            .set(RedisKey("job:\(jobIdentifier.string)"), to: Data("not JSON".utf8))
            .get()
    }

    func addMalformedIdentifierToProcessing(
        for queue: any Queue,
        using redis: any RedisClient
    ) async throws {
        _ = try await redis
            .lpush(Data([0xFF]), into: RedisKey("\(queue.key)-processing"))
            .get()
    }

    func deleteTestKeys(
        for queue: any Queue,
        jobIdentifiers: [JobIdentifier],
        using redis: any RedisClient
    ) async throws {
        let keys = [
            RedisKey(queue.key),
            RedisKey("\(queue.key)-processing"),
            RedisKey("\(queue.key)-unrelated-waiting"),
            RedisKey("\(queue.key)-unrelated-processing")
        ] + jobIdentifiers.map { RedisKey("job:\($0.string)") }
        _ = try await redis.delete(keys).get()
    }
}

private enum ModelArtifactQueueRecoveryTestError: Error {
    case redisQueueDriverUnavailable
}
