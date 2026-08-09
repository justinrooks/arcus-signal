import Foundation
import Queues
import Redis

/// Reads the Redis-backed model-artifact queue without changing it.
///
/// Issue #195 will apply the plan atomically before workers start. Keeping this
/// reader mutation-free lets the Redis driver contract be characterized safely.
struct ModelArtifactQueueRecoveryStore {
    private let queue: any Queue
    private let redis: any RedisClient

    init(queue: any Queue, redis: any RedisClient) {
        self.queue = queue
        self.redis = redis
    }

    func snapshot() async throws -> ModelArtifactQueueRecoverySnapshot {
        let waitingJobIdentifiers = try await jobIdentifiers(in: RedisKey(queue.key))
        let processingEntries = try await processingEntries()

        return ModelArtifactQueueRecoverySnapshot(
            waitingJobIdentifiers: waitingJobIdentifiers,
            processingEntries: processingEntries
        )
    }

    private var processingKey: String {
        "\(queue.key)-processing"
    }

    private func jobIdentifiers(in key: RedisKey) async throws -> [JobIdentifier] {
        let values = try await redis
            .lrange(from: key, firstIndex: 0, lastIndex: -1, as: Data.self)
            .get()

        return values.compactMap { value in
            value.flatMap { String(data: $0, encoding: .utf8) }
        }.map(JobIdentifier.init(string:))
    }

    private func processingEntries() async throws -> [ModelArtifactQueueProcessingEntry] {
        let values = try await redis
            .lrange(from: RedisKey(processingKey), firstIndex: 0, lastIndex: -1, as: Data.self)
            .get()

        return try await values.asyncMap { value in
            guard let value,
                  let identifier = String(data: value, encoding: .utf8) else {
                return .malformedIdentifier
            }

            let jobIdentifier = JobIdentifier(string: identifier)
            return .job(
                jobIdentifier: jobIdentifier,
                jobDataState: try await jobDataState(for: jobIdentifier)
            )
        }
    }

    private func jobDataState(for jobIdentifier: JobIdentifier) async throws -> ModelArtifactQueueJobDataState {
        guard let data = try await redis
            .get(RedisKey("job:\(jobIdentifier.string)"), as: Data.self)
            .get() else {
            return .missing
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        do {
            return .named(try decoder.decode(JobData.self, from: data).jobName)
        } catch {
            return .malformed
        }
    }
}

enum ModelArtifactQueueProcessingEntry: Sendable, Equatable {
    case job(jobIdentifier: JobIdentifier, jobDataState: ModelArtifactQueueJobDataState)
    case malformedIdentifier
}

enum ModelArtifactQueueJobDataState: Sendable, Equatable {
    case named(String)
    case missing
    case malformed
}

struct ModelArtifactQueueRecoverySnapshot: Sendable, Equatable {
    let waitingJobIdentifiers: [JobIdentifier]
    let processingEntries: [ModelArtifactQueueProcessingEntry]

    func plan(knownJobNames: Set<String>) -> ModelArtifactQueueRecoveryPlan {
        let waitingJobIdentifiers = Set(waitingJobIdentifiers)
        var handledJobIdentifiers = Set<JobIdentifier>()
        var actions = [ModelArtifactQueueRecoveryAction]()

        for entry in processingEntries {
            guard case let .job(jobIdentifier, jobDataState) = entry else {
                actions.append(.preserveMalformedIdentifier)
                continue
            }

            guard handledJobIdentifiers.insert(jobIdentifier).inserted else {
                continue
            }

            switch jobDataState {
            case .missing:
                actions.append(.preserveMissingJobData(jobIdentifier))
            case .malformed:
                actions.append(.preserveMalformedJobData(jobIdentifier))
            case let .named(jobName):
                guard knownJobNames.contains(jobName) else {
                    actions.append(.preserveUnknownJob(jobIdentifier, jobName: jobName))
                    continue
                }

                if waitingJobIdentifiers.contains(jobIdentifier) {
                    actions.append(.removeProcessingDuplicate(jobIdentifier))
                } else {
                    actions.append(.returnToWaiting(jobIdentifier))
                }
            }
        }

        return ModelArtifactQueueRecoveryPlan(actions: actions)
    }
}

struct ModelArtifactQueueRecoveryPlan: Sendable, Equatable {
    let actions: [ModelArtifactQueueRecoveryAction]
}

enum ModelArtifactQueueRecoveryAction: Sendable, Equatable {
    case returnToWaiting(JobIdentifier)
    case removeProcessingDuplicate(JobIdentifier)
    case preserveMissingJobData(JobIdentifier)
    case preserveMalformedJobData(JobIdentifier)
    case preserveMalformedIdentifier
    case preserveUnknownJob(JobIdentifier, jobName: String)
}

enum ModelArtifactQueueRecoveryContract {
    static let knownJobNames: Set<String> = [
        PressureArtifactWarmJob.name,
        PressureArtifactFailureCompletionJob.name,
        CleanupPressureArtifactsJob.name
    ]
}

private extension Array {
    func asyncMap<T: Sendable>(
        _ transform: (Element) async throws -> T
    ) async throws -> [T] {
        var values = [T]()
        values.reserveCapacity(count)
        for element in self {
            values.append(try await transform(element))
        }
        return values
    }
}
