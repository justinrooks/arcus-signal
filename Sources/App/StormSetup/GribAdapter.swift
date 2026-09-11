//
//  GribAdapter.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation
import NIOConcurrencyHelpers
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut(timeoutSeconds: TimeInterval, stderr: String)
    case nonZeroExit(code: Int32, stderr: String)
}

struct ProcessRunner: Sendable {
    private enum WaitOutcome {
        case exited
        case timedOut
    }

    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval = 10
    ) async throws -> ProcessResult {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let pipes = ProcessPipeResources()
        let stdoutReader = ProcessPipeReader(fileHandle: pipes.stdoutReadingHandle)
        let stderrReader = ProcessPipeReader(fileHandle: pipes.stderrReadingHandle)
        var processWasLaunched = false
        defer {
            if processWasLaunched {
                pipes.closeWritingEnds()
            } else {
                pipes.closeAll()
            }
        }
        process.standardOutput = pipes.stdoutPipe
        process.standardError = pipes.stderrPipe

        let exitObservation = ProcessExitObservation()
        process.terminationHandler = { _ in
            exitObservation.processDidExit()
            stdoutReader.processDidExit()
            stderrReader.processDidExit()
        }

        do {
            try process.run()
        } catch {
            try Task.checkCancellation()
            throw ProcessRunnerError.launchFailed(
                "Failed to launch \(executableURL.path): \(error.localizedDescription)"
            )
        }
        processWasLaunched = true
        return try await withTaskCancellationHandler {
            let stdoutData = Task { await stdoutReader.readToEnd() }
            let stderrData = Task { await stderrReader.readToEnd() }
            pipes.closeWritingEnds()

            let waitOutcome: WaitOutcome
            do {
                waitOutcome = try await Self.waitForExit(
                    process,
                    timeoutSeconds: timeoutSeconds
                )
            } catch is CancellationError {
                await Self.terminateAndReap(
                    process,
                    exitObservation: exitObservation,
                    sendTerminationSignal: false
                )
                stdoutReader.processDidExit()
                stderrReader.processDidExit()
                _ = await Self.collectPipeData(
                    stdoutTask: stdoutData,
                    stderrTask: stderrData,
                    stdoutReader: stdoutReader,
                    stderrReader: stderrReader
                )
                throw CancellationError()
            }

            switch waitOutcome {
            case .exited:
                await exitObservation.waitForExit()
            case .timedOut:
                await Self.terminateAndReap(
                    process,
                    exitObservation: exitObservation,
                    sendTerminationSignal: true
                )
            }

            stdoutReader.processDidExit()
            stderrReader.processDidExit()
            let (capturedStdout, capturedStderr) = await Self.collectPipeData(
                stdoutTask: stdoutData,
                stderrTask: stderrData,
                stdoutReader: stdoutReader,
                stderrReader: stderrReader
            )
            let result = ProcessResult(
                stdout: String(data: capturedStdout, encoding: .utf8) ?? "",
                stderr: String(data: capturedStderr, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )

            // Cancellation wins while lifecycle cleanup is still in flight.
            try Task.checkCancellation()

            if waitOutcome == .timedOut {
                throw ProcessRunnerError.timedOut(
                    timeoutSeconds: timeoutSeconds,
                    stderr: result.stderr
                )
            }

            guard result.exitCode == 0 else {
                throw ProcessRunnerError.nonZeroExit(
                    code: result.exitCode,
                    stderr: result.stderr
                )
            }

            return result
        } onCancel: {
            if process.isRunning {
                process.terminate()
            }
            stdoutReader.cancel()
            stderrReader.cancel()
        }
    }

    private enum PipeCollectionResult: Sendable {
        case stdout(Data)
        case stderr(Data)
        case cleanupTimedOut
    }

    private static func collectPipeData(
        stdoutTask: Task<Data, Never>,
        stderrTask: Task<Data, Never>,
        stdoutReader: ProcessPipeReader,
        stderrReader: ProcessPipeReader
    ) async -> (stdout: Data, stderr: Data) {
        await withTaskGroup(of: PipeCollectionResult.self) { group in
            group.addTask {
                .stdout(await stdoutTask.value)
            }
            group.addTask {
                .stderr(await stderrTask.value)
            }
            group.addTask {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    return .cleanupTimedOut
                } catch {
                    return .cleanupTimedOut
                }
            }

            var stdout = Data()
            var stderr = Data()
            var completedReaders = 0

            while let result = await group.next() {
                switch result {
                case .stdout(let data):
                    stdout = data
                    completedReaders += 1
                case .stderr(let data):
                    stderr = data
                    completedReaders += 1
                case .cleanupTimedOut:
                    stdoutReader.cancel()
                    stderrReader.cancel()
                    group.cancelAll()
                }

                if completedReaders == 2 {
                    group.cancelAll()
                    break
                }
            }

            return (stdout, stderr)
        }
    }

    private static func waitForExit(
        _ process: Process,
        timeoutSeconds: TimeInterval
    ) async throws -> WaitOutcome {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while process.isRunning {
            if Date() > deadline {
                return .timedOut
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        return .exited
    }

    private static func terminateAndReap(
        _ process: Process,
        exitObservation: ProcessExitObservation,
        sendTerminationSignal: Bool
    ) async {
        if sendTerminationSignal, process.isRunning {
            process.terminate()
        }

        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < graceDeadline {
            await sleepIgnoringCancellation(for: 0.05)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        await exitObservation.waitForExit()
    }

    private static func sleepIgnoringCancellation(for interval: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + interval
            ) {
                continuation.resume()
            }
        }
    }
}

private final class ProcessPipeResources: Sendable {
    private struct State: Sendable {
        var stdoutReadClosed = false
        var stdoutWriteClosed = false
        var stderrReadClosed = false
        var stderrWriteClosed = false
    }

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()

    var stdoutReadingHandle: FileHandle { stdoutPipe.fileHandleForReading }
    var stderrReadingHandle: FileHandle { stderrPipe.fileHandleForReading }

    private let state = NIOLockedValueBox(State())

    func closeWritingEnds() {
        let handles = state.withLockedValue { state -> [FileHandle] in
            var handles: [FileHandle] = []

            if !state.stdoutWriteClosed {
                state.stdoutWriteClosed = true
                handles.append(stdoutPipe.fileHandleForWriting)
            }
            if !state.stderrWriteClosed {
                state.stderrWriteClosed = true
                handles.append(stderrPipe.fileHandleForWriting)
            }

            return handles
        }

        handles.forEach { $0.closeFile() }
    }

    func closeAll() {
        let handles = state.withLockedValue { state -> [FileHandle] in
            var handles: [FileHandle] = []

            if !state.stdoutReadClosed {
                state.stdoutReadClosed = true
                handles.append(stdoutPipe.fileHandleForReading)
            }
            if !state.stdoutWriteClosed {
                state.stdoutWriteClosed = true
                handles.append(stdoutPipe.fileHandleForWriting)
            }
            if !state.stderrReadClosed {
                state.stderrReadClosed = true
                handles.append(stderrPipe.fileHandleForReading)
            }
            if !state.stderrWriteClosed {
                state.stderrWriteClosed = true
                handles.append(stderrPipe.fileHandleForWriting)
            }

            return handles
        }

        handles.forEach {
            $0.readabilityHandler = nil
            $0.closeFile()
        }
    }
}

private final class ProcessExitObservation: Sendable {
    private struct State: Sendable {
        var didExit = false
        var continuation: CheckedContinuation<Void, Never>?
    }

    private let state = NIOLockedValueBox(State())

    func processDidExit() {
        let continuation = state.withLockedValue { state in
            state.didExit = true
            defer { state.continuation = nil }
            return state.continuation
        }
        continuation?.resume()
    }

    func waitForExit() async {
        await withCheckedContinuation { continuation in
            let shouldResume = state.withLockedValue { state in
                if state.didExit {
                    return true
                }

                state.continuation = continuation
                return false
            }

            if shouldResume {
                continuation.resume()
            }
        }
    }
}

private final class ProcessPipeReader: Sendable {
    private struct State: Sendable {
        var data = Data()
        var continuation: CheckedContinuation<Data, Never>?
        var isFinished = false
        var processDidExit = false
        var isReading = false
    }

    private let fileHandle: FileHandle
    private let state = NIOLockedValueBox(State())

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            let shouldStartReading = state.withLockedValue { state -> Bool in
                if state.isFinished {
                    continuation.resume(returning: state.data)
                    return false
                }

                state.continuation = continuation
                return true
            }

            guard shouldStartReading else {
                return
            }

            fileHandle.readabilityHandler = { [self] readableHandle in
                consumeAvailableData(from: readableHandle)
            }

            let (isFinished, processExited) = state.withLockedValue { state in
                (state.isFinished, state.processDidExit)
            }
            if isFinished {
                fileHandle.readabilityHandler = nil
            } else if processExited {
                processDidExit()
            }
        }
    }

    func processDidExit() {
        let shouldDrain = state.withLockedValue { state -> Bool in
            state.processDidExit = true
            guard !state.isFinished, state.continuation != nil, !state.isReading else {
                return false
            }

            state.isReading = true
            return true
        }

        if shouldDrain {
            drainAvailableData()
        }
    }

    func cancel() {
        let completion: (CheckedContinuation<Data, Never>, Data)? = state.withLockedValue { state in
            guard !state.isFinished else {
                return nil
            }

            state.isFinished = true
            state.isReading = false
            guard let continuation = state.continuation else {
                return nil
            }

            state.continuation = nil
            return (continuation, state.data)
        }

        fileHandle.readabilityHandler = nil
        fileHandle.closeFile()
        if let completion {
            completion.0.resume(returning: completion.1)
        }
    }

    private func consumeAvailableData(from readableHandle: FileHandle) {
        let shouldRead = state.withLockedValue { state -> Bool in
            guard !state.isFinished, !state.isReading else {
                return false
            }

            state.isReading = true
            return true
        }

        guard shouldRead else {
            return
        }

        drainAvailableData(from: readableHandle)
    }

    private func drainAvailableData(from readableHandle: FileHandle? = nil) {
        let handle = readableHandle ?? fileHandle

        while true {
            let data = handle.availableData
            let result = state.withLockedValue { state -> DrainResult in
                guard !state.isFinished else {
                    return .alreadyFinished
                }

                guard !data.isEmpty else {
                    state.isFinished = true
                    state.isReading = false
                    let continuation = state.continuation
                    state.continuation = nil
                    return .completed(continuation, state.data)
                }

                state.data.append(data)
                return state.processDidExit ? .continueReading : .pauseReading
            }

            switch result {
            case .alreadyFinished:
                return
            case .completed(let continuation, let data):
                fileHandle.readabilityHandler = nil
                fileHandle.closeFile()
                continuation?.resume(returning: data)
                return
            case .pauseReading:
                state.withLockedValue { state in
                    state.isReading = false
                }
                return
            case .continueReading:
                continue
            }
        }
    }

    private enum DrainResult {
        case alreadyFinished
        case completed(CheckedContinuation<Data, Never>?, Data)
        case pauseReading
        case continueReading
    }
}
