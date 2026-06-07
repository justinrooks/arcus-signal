//
//  GribAdapter.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation

struct ProcessResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

enum ProcessRunnerError: Error {
    case launchFailed(String)
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

            try process.run()

            let deadline = Date().addingTimeInterval(timeoutSeconds)

            while process.isRunning {
                if Date() > deadline {
                    process.terminate()
                    throw ProcessRunnerError.launchFailed("Process timed out")
                }

//                Thread.sleep(forTimeInterval: 0.05)
            }

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            let result = ProcessResult(
                stdout: stdout,
                stderr: stderr,
                exitCode: process.terminationStatus
            )

            guard result.exitCode == 0 else {
                throw ProcessRunnerError.nonZeroExit(
                    code: result.exitCode,
                    stderr: result.stderr
                )
            }

            return result
        }.value
    }
}
