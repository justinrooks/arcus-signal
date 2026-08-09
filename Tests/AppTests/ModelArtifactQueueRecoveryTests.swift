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

    func storeJob(named jobName: String, with jobIdentifier: JobIdentifier, in queue: any Queue) async throws {
        try await queue.set(
            jobIdentifier,
            to: JobData(
                payload: [],
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
            RedisKey("\(queue.key)-processing")
        ] + jobIdentifiers.map { RedisKey("job:\($0.string)") }
        _ = try await redis.delete(keys).get()
    }
}

private enum ModelArtifactQueueRecoveryTestError: Error {
    case redisQueueDriverUnavailable
}
