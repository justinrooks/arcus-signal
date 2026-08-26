@testable import App
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing

@Suite("Process runner", .serialized)
struct ProcessRunnerTests {
    @Test("captures empty stdout and stderr for successful commands")
    func capturesEmptyStandardOutputAndError() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let result = try await ProcessRunner().run(
            executableURL: fixture.executableURL,
            arguments: ["empty"],
            timeoutSeconds: 1
        )

        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test("captures stdout and stderr for successful commands")
    func capturesStandardOutputAndError() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let result = try await ProcessRunner().run(
            executableURL: fixture.executableURL,
            arguments: ["success"],
            timeoutSeconds: 1
        )

        #expect(result.stdout == "line one\n")
        #expect(result.stderr == "line two\n")
        #expect(result.exitCode == 0)
    }

    @Test("preserves non-zero exit status and stderr")
    func preservesNonZeroExit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        do {
            _ = try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: ["nonzero"],
                timeoutSeconds: 1
            )
            Issue.record("Expected a non-zero exit error.")
        } catch let error as ProcessRunnerError {
            guard case .nonZeroExit(let code, let stderr) = error else {
                Issue.record("Expected a nonZeroExit error, got \(error).")
                return
            }

            #expect(code == 7)
            #expect(stderr == "boom\n")
        }
    }

    @Test("timeout escalates after TERM and leaves no child")
    func timeoutEscalatesAndReapsChild() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        do {
            _ = try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: fixture.waitingArguments(mode: "timeout"),
                timeoutSeconds: 0.2
            )
            Issue.record("Expected a timeout error.")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let timeoutSeconds, let stderr) = error else {
                Issue.record("Expected a timedOut error, got \(error).")
                return
            }

            #expect(abs(timeoutSeconds - 0.2) < 0.0001)
            #expect(stderr == "waiting for timeout\n")
        }

        let pid = try fixture.recordedPID()
        #expect(FileManager.default.fileExists(atPath: fixture.termURL.path))
        #expect(!isProcessRunning(pid))
    }

    @Test("drains large stdout and stderr concurrently")
    func drainsLargeStandardOutputAndError() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let result = try await ProcessRunner().run(
            executableURL: fixture.executableURL,
            arguments: ["large"],
            timeoutSeconds: 2
        )

        let stdoutLines = result.stdout.split(whereSeparator: \.isNewline)
        let stderrLines = result.stderr.split(whereSeparator: \.isNewline)

        #expect(result.exitCode == 0)
        #expect(stdoutLines.count == 15000)
        #expect(stderrLines.count == 15000)
        #expect(stdoutLines.first == "stdout-00001")
        #expect(stdoutLines.last == "stdout-15000")
        #expect(stderrLines.first == "stderr-00001")
        #expect(stderrLines.last == "stderr-15000")
    }

    @Test("cancellation waits for a TERM-cooperative child")
    func cancellationReapsGracefulChild() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: fixture.waitingArguments(mode: "graceful"),
                timeoutSeconds: 10
            )
        }

        try await waitForFile(fixture.readyURL)
        let pid = try fixture.recordedPID()
        let clock = ContinuousClock()
        let cancellationStart = clock.now
        task.cancel()

        await expectCancellation(from: task)
        let cancellationDuration = cancellationStart.duration(to: clock.now)

        #expect(FileManager.default.fileExists(atPath: fixture.termURL.path))
        #expect(!isProcessRunning(pid))
        #expect(cancellationDuration < .seconds(1.5))
    }

    @Test("cancellation force-kills a TERM-resistant child")
    func cancellationForceKillsAndReapsChild() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let task = Task {
            try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: fixture.waitingArguments(mode: "ignore-term"),
                timeoutSeconds: 10
            )
        }

        try await waitForFile(fixture.readyURL)
        let pid = try fixture.recordedPID()
        let clock = ContinuousClock()
        let cancellationStart = clock.now
        task.cancel()

        await expectCancellation(from: task)
        let cancellationDuration = cancellationStart.duration(to: clock.now)

        #expect(FileManager.default.fileExists(atPath: fixture.termURL.path))
        #expect(!isProcessRunning(pid))
        #expect(cancellationDuration >= .milliseconds(350))
        #expect(cancellationDuration < .seconds(1.5))
    }

    @Test("cancellation before launch does not create a child")
    func cancellationBeforeLaunchDoesNotCreateChild() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let task = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: fixture.waitingArguments(mode: "graceful"),
                timeoutSeconds: 10
            )
        }

        await expectCancellation(from: task)

        #expect(!FileManager.default.fileExists(atPath: fixture.pidURL.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.readyURL.path))
    }

    @Test("preserves launch failure mapping")
    func preservesLaunchFailure() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-process-runner-\(UUID().uuidString)")

        do {
            _ = try await ProcessRunner().run(
                executableURL: missingURL,
                arguments: [],
                timeoutSeconds: 1
            )
            Issue.record("Expected a launch failure.")
        } catch let error as ProcessRunnerError {
            guard case .launchFailed(let message) = error else {
                Issue.record("Expected launchFailed, got \(error).")
                return
            }

            #expect(message.hasPrefix("Failed to launch \(missingURL.path): "))
        }
    }

    @Test("releases pipe descriptors after repeated success and timeout runs")
    func releasesPipeDescriptorsAfterRepeatedRuns() async throws {
        #if os(Linux)
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let baseline = try openFileDescriptorCount()

        for _ in 0..<40 {
            _ = try await ProcessRunner().run(
                executableURL: fixture.executableURL,
                arguments: ["success"],
                timeoutSeconds: 1
            )
        }

        for _ in 0..<20 {
            do {
                _ = try await ProcessRunner().run(
                    executableURL: fixture.executableURL,
                    arguments: fixture.waitingArguments(mode: "timeout"),
                    timeoutSeconds: 0.1
                )
                Issue.record("Expected a timeout error.")
            } catch let error as ProcessRunnerError {
                guard case .timedOut = error else {
                    Issue.record("Expected a timeout error, got \(error).")
                    continue
                }
            }
        }

        let finalCount = try openFileDescriptorCount()
        #expect(finalCount <= baseline + 12)
        #endif
    }

    private func makeFixture() throws -> FixtureContext {
        guard let bundledURL = Bundle.module.url(
            forResource: "ProcessRunnerFixture",
            withExtension: "py",
            subdirectory: "Fixtures"
        ) else {
            throw ProcessRunnerTestError.missingFixture
        }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("process-runner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let executableURL = directoryURL.appendingPathComponent("ProcessRunnerFixture.py")
        try FileManager.default.copyItem(at: bundledURL, to: executableURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        return FixtureContext(directoryURL: directoryURL, executableURL: executableURL)
    }

    private func waitForFile(
        _ url: URL,
        timeoutSeconds: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)

        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else {
                throw ProcessRunnerTestError.markerTimedOut(url)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func expectCancellation(from task: Task<ProcessResult, any Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    private func isProcessRunning(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count
    }
}

private struct FixtureContext: Sendable {
    let directoryURL: URL
    let executableURL: URL

    var pidURL: URL { directoryURL.appendingPathComponent("child.pid") }
    var readyURL: URL { directoryURL.appendingPathComponent("ready") }
    var termURL: URL { directoryURL.appendingPathComponent("term") }

    func waitingArguments(mode: String) -> [String] {
        [mode, pidURL.path, readyURL.path, termURL.path]
    }

    func recordedPID() throws -> pid_t {
        let contents = try String(contentsOf: pidURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(contents) else {
            throw ProcessRunnerTestError.invalidPID(contents)
        }
        return pid
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private enum ProcessRunnerTestError: Error {
    case invalidPID(String)
    case markerTimedOut(URL)
    case missingFixture
}
