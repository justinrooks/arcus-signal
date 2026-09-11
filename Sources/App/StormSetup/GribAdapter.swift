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
    case pipeCleanupTimedOut
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
            Task {
                await stdoutReader.processDidExit()
                await stderrReader.processDidExit()
            }
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
                await stdoutReader.processDidExit()
                await stderrReader.processDidExit()
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

            await stdoutReader.processDidExit()
            await stderrReader.processDidExit()
            let collected = await Self.collectPipeData(
                stdoutTask: stdoutData,
                stderrTask: stderrData,
                stdoutReader: stdoutReader,
                stderrReader: stderrReader
            )
            let result = ProcessResult(
                stdout: String(data: collected.stdout, encoding: .utf8) ?? "",
                stderr: String(data: collected.stderr, encoding: .utf8) ?? "",
                exitCode: process.terminationStatus
            )

            // Cancellation wins while lifecycle cleanup is still in flight.
            try Task.checkCancellation()

            if collected.didTimeOut, waitOutcome == .exited {
                throw ProcessRunnerError.pipeCleanupTimedOut
            }

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
            Task {
                await stdoutReader.cancel()
                await stderrReader.cancel()
            }
        }
    }

    private enum PipeCollectionResult: Sendable {
        case stdout(Data)
        case stderr(Data)
        case cleanupTimedOut
    }

    private struct PipeCollection: Sendable {
        let stdout: Data
        let stderr: Data
        let didTimeOut: Bool
    }

    private static func collectPipeData(
        stdoutTask: Task<Data, Never>,
        stderrTask: Task<Data, Never>,
        stdoutReader: ProcessPipeReader,
        stderrReader: ProcessPipeReader
    ) async -> PipeCollection {
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
            var didTimeOut = false

            while let result = await group.next() {
                switch result {
                case .stdout(let data):
                    stdout = data
                    completedReaders += 1
                case .stderr(let data):
                    stderr = data
                    completedReaders += 1
                case .cleanupTimedOut:
                    didTimeOut = true
                    await stdoutReader.cancel()
                    await stderrReader.cancel()
                    group.cancelAll()
                }

                if completedReaders == 2 {
                    group.cancelAll()
                    break
                }
            }

            return PipeCollection(stdout: stdout, stderr: stderr, didTimeOut: didTimeOut)
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

actor ProcessPipeReader {
    private let fileHandle: FileHandle
    private let fileDescriptor: Int32
    private let installReadSource: Bool
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Never>?
    private var isFinished = false
    private var didProcessExit = false
    private var readSource: (any DispatchSourceRead)?
    private var fileHandleIsClosed = false

    init(fileHandle: FileHandle, installReadSource: Bool = true) {
        self.fileHandle = fileHandle
        fileDescriptor = fileHandle.fileDescriptor
        self.installReadSource = installReadSource

        let flags = fcntl(fileDescriptor, F_GETFL)
        precondition(flags >= 0, "Failed to inspect process pipe flags.")
        precondition(
            fcntl(fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0,
            "Failed to make process pipe nonblocking."
        )
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume(returning: data)
                return
            }

            self.continuation = continuation
            installReadSourceIfNeeded()
            if didProcessExit {
                drainAvailableData()
            }
        }
    }

    func processDidExit() {
        guard !isFinished, !didProcessExit else {
            return
        }

        didProcessExit = true
        drainAvailableData()
    }

    func cancel() {
        guard !isFinished else { return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        close()
        continuation?.resume(returning: data)
    }

    private func drainAvailableData() {
        while true {
            guard !isFinished, !fileHandleIsClosed else { return }

            var buffer = [UInt8](repeating: 0, count: 8_192)
            let count = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else {
                    return 0
                }
                return read(fileDescriptor, baseAddress, rawBuffer.count)
            }

            if count > 0 {
                data.append(contentsOf: buffer[0..<count])
                continue
            }

            if count == 0 {
                finish()
                return
            }

            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                return
            }

            return
        }
    }

    private func installReadSourceIfNeeded() {
        guard installReadSource, readSource == nil, !isFinished, !fileHandleIsClosed else {
            return
        }

        let source = DispatchSource.makeReadSource(
            fileDescriptor: fileDescriptor,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.drainAvailableData() }
        }
        readSource = source
        source.resume()
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        close()
        continuation?.resume(returning: data)
    }

    private func close() {
        guard !fileHandleIsClosed else { return }
        fileHandleIsClosed = true
        readSource?.cancel()
        readSource = nil
        fileHandle.closeFile()
    }
}
