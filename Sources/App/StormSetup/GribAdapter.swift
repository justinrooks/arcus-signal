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

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exitObservation = ProcessExitObservation()
        process.terminationHandler = { _ in
            exitObservation.processDidExit()
        }

        do {
            try process.run()
        } catch {
            try Task.checkCancellation()
            throw ProcessRunnerError.launchFailed(
                "Failed to launch \(executableURL.path): \(error.localizedDescription)"
            )
        }

        return try await withTaskCancellationHandler {
            let stdoutReader = ProcessPipeReader(fileHandle: stdoutPipe.fileHandleForReading)
            let stderrReader = ProcessPipeReader(fileHandle: stderrPipe.fileHandleForReading)
            async let stdoutData = stdoutReader.readToEnd()
            async let stderrData = stderrReader.readToEnd()

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
                _ = await (stdoutData, stderrData)
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

            let (capturedStdout, capturedStderr) = await (stdoutData, stderrData)
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
    }

    private let fileHandle: FileHandle
    private let state = NIOLockedValueBox(State())

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    func readToEnd() async -> Data {
        await withCheckedContinuation { continuation in
            state.withLockedValue { state in
                state.continuation = continuation
            }

            fileHandle.readabilityHandler = { [self] readableHandle in
                consumeAvailableData(from: readableHandle)
            }
        }
    }

    private func consumeAvailableData(from readableHandle: FileHandle) {
        let completion: (CheckedContinuation<Data, Never>, Data)? = state.withLockedValue { state in
            guard !state.isFinished else {
                return nil
            }

            let data = readableHandle.availableData
            guard data.isEmpty else {
                state.data.append(data)
                return nil
            }

            state.isFinished = true
            guard let continuation = state.continuation else {
                return nil
            }
            state.continuation = nil
            return (continuation, state.data)
        }

        guard let completion else {
            return
        }

        fileHandle.readabilityHandler = nil
        completion.0.resume(returning: completion.1)
    }
}
