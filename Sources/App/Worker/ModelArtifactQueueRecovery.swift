import Foundation
import Queues
@preconcurrency import Redis

/// Inspects and atomically reconciles the Redis-backed model-artifact queue.
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

    func recoverKnownJobs(
        knownJobNames: Set<String> = ModelArtifactQueueRecoveryContract.knownJobNames
    ) async throws -> ModelArtifactQueueRecoverySummary {
        let arguments = [
            RESPValue(from: Self.recoveryScript),
            RESPValue(from: 2),
            RESPValue(from: queue.key),
            RESPValue(from: processingKey)
        ] + knownJobNames.sorted().map { RESPValue(from: $0) }
        let response = try await redis.send(command: "EVAL", with: arguments).get()
        return try Self.decodeSummary(response)
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

    private static func decodeSummary(_ response: RESPValue) throws -> ModelArtifactQueueRecoverySummary {
        guard let values = response.array,
              values.count == 10,
              let inspectedEntryCount = values[0].int,
              let returnedToWaitingCount = values[1].int,
              let alreadyWaitingCount = values[2].int,
              let removedProcessingEntryCount = values[3].int,
              let preservedMissingJobDataCount = values[4].int,
              let preservedMalformedJobDataCount = values[5].int,
              let preservedMalformedIdentifierCount = values[6].int,
              let preservedUnknownJobCount = values[7].int,
              let returnedValues = values[8].array,
              let alreadyWaitingValues = values[9].array else {
            throw ModelArtifactQueueRecoveryError.invalidScriptResponse
        }

        let returnedJobIdentifiers = try jobIdentifiers(from: returnedValues)
        let alreadyWaitingJobIdentifiers = try jobIdentifiers(from: alreadyWaitingValues)
        guard returnedToWaitingCount == returnedJobIdentifiers.count,
              alreadyWaitingCount == alreadyWaitingJobIdentifiers.count else {
            throw ModelArtifactQueueRecoveryError.invalidScriptResponse
        }

        return ModelArtifactQueueRecoverySummary(
            inspectedEntryCount: inspectedEntryCount,
            returnedJobIdentifiers: returnedJobIdentifiers,
            alreadyWaitingJobIdentifiers: alreadyWaitingJobIdentifiers,
            removedProcessingEntryCount: removedProcessingEntryCount,
            preservedMissingJobDataCount: preservedMissingJobDataCount,
            preservedMalformedJobDataCount: preservedMalformedJobDataCount,
            preservedMalformedIdentifierCount: preservedMalformedIdentifierCount,
            preservedUnknownJobCount: preservedUnknownJobCount
        )
    }

    private static func jobIdentifiers(from values: [RESPValue]) throws -> [String] {
        try values.map { value in
            guard let identifier = value.string else {
                throw ModelArtifactQueueRecoveryError.invalidScriptResponse
            }
            return identifier
        }
    }

    /// Redis executes this script atomically. It classifies every entry before
    /// applying any mutation so malformed queue state cannot produce a partial
    /// recovery merely because a later entry cannot be inspected.
    private static let recoveryScript = #"""
    local waiting_key = KEYS[1]
    local processing_key = KEYS[2]

    local known_job_names = {}
    for index = 1, #ARGV do
        known_job_names[ARGV[index]] = true
    end

    local function is_valid_utf8(value)
        local continuation_count = 0
        local continuation_minimum = 128
        local continuation_maximum = 191
        for index = 1, #value do
            local first = string.byte(value, index)
            if continuation_count > 0 then
                if first < continuation_minimum or first > continuation_maximum then return false end
                continuation_count = continuation_count - 1
                continuation_minimum = 128
                continuation_maximum = 191
            elseif first <= 127 then
                continuation_count = 0
            elseif first >= 194 and first <= 223 then
                continuation_count = 1
            elseif first >= 224 and first <= 239 then
                continuation_count = 2
                if first == 224 then continuation_minimum = 160 end
                if first == 237 then continuation_maximum = 159 end
            elseif first >= 240 and first <= 244 then
                continuation_count = 3
                if first == 240 then continuation_minimum = 144 end
                if first == 244 then continuation_maximum = 143 end
            else
                return false
            end
        end
        return continuation_count == 0
    end

    local function is_nonnegative_integer(value)
        return type(value) == 'number' and value >= 0 and value == math.floor(value)
    end

    local function skip_whitespace(value, index)
        while index <= #value do
            local byte = string.byte(value, index)
            if byte ~= 9 and byte ~= 10 and byte ~= 13 and byte ~= 32 then break end
            index = index + 1
        end
        return index
    end

    local function string_end(value, index)
        index = index + 1
        while index <= #value do
            local byte = string.byte(value, index)
            if byte == 34 then return index + 1 end
            if byte == 92 then index = index + 1 end
            index = index + 1
        end
        return nil
    end

    -- Redis cjson represents both [] and {} as an empty Lua table. Inspect the
    -- validated raw JSON so an empty object cannot masquerade as a byte array.
    local function has_single_array_payload(value)
        local depth = 0
        local payload_count = 0
        local index = 1
        while index <= #value do
            local byte = string.byte(value, index)
            if byte == 34 then
                local token_start = index
                local token_end = string_end(value, index)
                if not token_end then return false end
                if depth == 1 then
                    local colon_index = skip_whitespace(value, token_end)
                    if string.byte(value, colon_index) == 58 then
                        local decoded_ok, key = pcall(
                            cjson.decode,
                            string.sub(value, token_start, token_end - 1)
                        )
                        if not decoded_ok then return false end
                        if key == 'payload' then
                            payload_count = payload_count + 1
                            local payload_index = skip_whitespace(value, colon_index + 1)
                            if string.byte(value, payload_index) ~= 91 then return false end
                        end
                    end
                end
                index = token_end
            elseif byte == 123 or byte == 91 then
                depth = depth + 1
                index = index + 1
            elseif byte == 125 or byte == 93 then
                depth = depth - 1
                index = index + 1
            else
                index = index + 1
            end
        end
        return payload_count == 1
    end

    local function is_valid_payload(payload)
        if type(payload) ~= 'table' then return false end
        local count = 0
        for index, byte in pairs(payload) do
            if type(index) ~= 'number' or index < 1 or index ~= math.floor(index) or
               not is_nonnegative_integer(byte) or byte > 255 then return false end
            count = count + 1
        end
        for index = 1, count do
            if payload[index] == nil then return false end
        end
        return true
    end

    local function is_valid_job_data(decoded, encoded)
        if type(decoded) ~= 'table' or
           not has_single_array_payload(encoded) or
           not is_valid_payload(decoded.payload) or
           not is_nonnegative_integer(decoded.maxRetryCount) or
           type(decoded.queuedAt) ~= 'number' or
           type(decoded.jobName) ~= 'string' then return false end

        if decoded.attempts ~= nil and decoded.attempts ~= cjson.null and
           not is_nonnegative_integer(decoded.attempts) then return false end
        if decoded.delayUntil ~= nil and decoded.delayUntil ~= cjson.null and
           type(decoded.delayUntil) ~= 'number' then return false end
        return true
    end

    local waiting_entries = redis.call('LRANGE', waiting_key, 0, -1)
    local processing_entries = redis.call('LRANGE', processing_key, 0, -1)
    local waiting_membership = {}
    for _, identifier in ipairs(waiting_entries) do
        waiting_membership[identifier] = true
    end

    local handled_identifiers = {}
    local actions = {}
    local returned_identifiers = {}
    local already_waiting_identifiers = {}
    local missing_count = 0
    local malformed_data_count = 0
    local malformed_identifier_count = 0
    local unknown_count = 0

    for _, identifier in ipairs(processing_entries) do
        if not is_valid_utf8(identifier) then
            malformed_identifier_count = malformed_identifier_count + 1
        elseif not handled_identifiers[identifier] then
            handled_identifiers[identifier] = true
            local job_data = redis.call('GET', 'job:' .. identifier)
            if not job_data then
                missing_count = missing_count + 1
            else
                local decoded_ok, decoded = pcall(cjson.decode, job_data)
                if not decoded_ok or not is_valid_job_data(decoded, job_data) then
                    malformed_data_count = malformed_data_count + 1
                elseif not known_job_names[decoded.jobName] then
                    unknown_count = unknown_count + 1
                elseif waiting_membership[identifier] then
                    table.insert(actions, { kind = 'already-waiting', identifier = identifier })
                    table.insert(already_waiting_identifiers, identifier)
                else
                    table.insert(actions, { kind = 'return', identifier = identifier })
                    table.insert(returned_identifiers, identifier)
                end
            end
        end
    end

    local removed_processing_entry_count = 0
    for _, action in ipairs(actions) do
        if action.kind == 'return' then
            redis.call('LPUSH', waiting_key, action.identifier)
        end
        removed_processing_entry_count = removed_processing_entry_count +
            redis.call('LREM', processing_key, 0, action.identifier)
    end

    return {
        #processing_entries,
        #returned_identifiers,
        #already_waiting_identifiers,
        removed_processing_entry_count,
        missing_count,
        malformed_data_count,
        malformed_identifier_count,
        unknown_count,
        returned_identifiers,
        already_waiting_identifiers
    }
    """#
}

struct ModelArtifactQueueRecoverySummary: Sendable, Equatable {
    let inspectedEntryCount: Int
    let returnedJobIdentifiers: [String]
    let alreadyWaitingJobIdentifiers: [String]
    let removedProcessingEntryCount: Int
    let preservedMissingJobDataCount: Int
    let preservedMalformedJobDataCount: Int
    let preservedMalformedIdentifierCount: Int
    let preservedUnknownJobCount: Int

    static let empty = ModelArtifactQueueRecoverySummary(
        inspectedEntryCount: 0,
        returnedJobIdentifiers: [],
        alreadyWaitingJobIdentifiers: [],
        removedProcessingEntryCount: 0,
        preservedMissingJobDataCount: 0,
        preservedMalformedJobDataCount: 0,
        preservedMalformedIdentifierCount: 0,
        preservedUnknownJobCount: 0
    )
}

enum ModelArtifactQueueRecoveryError: Error {
    case invalidScriptResponse
    case redisQueueDriverUnavailable
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
