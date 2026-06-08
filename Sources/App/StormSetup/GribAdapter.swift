//
//  GribAdapter.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation
import Darwin

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
    func run(
        executableURL: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval = 10
    ) async throws -> ProcessResult {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
            } catch {
                throw ProcessRunnerError.launchFailed(
                    "Failed to launch \(executableURL.path): \(error.localizedDescription)"
                )
            }

            let stdoutTask = Task.detached(priority: .utility) {
                Self.readPipeToEnd(stdoutPipe.fileHandleForReading)
            }
            let stderrTask = Task.detached(priority: .utility) {
                Self.readPipeToEnd(stderrPipe.fileHandleForReading)
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            var timedOut = false

            while process.isRunning {
                if Date() > deadline {
                    timedOut = true
                    process.terminate()
                    let graceDeadline = Date().addingTimeInterval(0.5)

                    while process.isRunning && Date() < graceDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }

                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                        process.waitUntilExit()
                    }

                    break
                }

                try await Task.sleep(for: .milliseconds(50))
            }

            if process.isRunning {
                process.waitUntilExit()
            }

            let stdoutData = await stdoutTask.value
            let stderrData = await stderrTask.value

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            let result = ProcessResult(
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus
            )

            if timedOut {
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
        }.value
    }

    private static func readPipeToEnd(_ fileHandle: FileHandle) -> Data {
        fileHandle.readDataToEndOfFile()
    }
}
