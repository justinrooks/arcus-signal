@testable import App
import Foundation
import Testing

@Suite("Storm setup wgrib2 client", .serialized)
struct StormSetupWgrib2ClientTests {
    @Test("wgrib2 point sample parser extracts value and preserves inventory text")
    func pointSampleParserExtractsValue() throws {
        let line = "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=1450"

        let sample = Wgrib2PointSample.parse(from: line)

        #expect(sample.inventory == line)
        #expect(sample.longitude == -104.47)
        #expect(sample.latitude == 39.79)
        #expect(sample.value == 1450)
    }

    @Test("wgrib2 point sample parser tolerates missing and non-numeric values")
    func pointSampleParserReturnsNilForMissingValue() throws {
        let missingValue = Wgrib2PointSample.parse(
            from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79"
        )
        let nonNumericValue = Wgrib2PointSample.parse(
            from: "1:0:d=2026060313:CAPE:surface:9 hour fcst:lon=-104.47,lat=39.79,val=missing"
        )

        #expect(missingValue.value == nil)
        #expect(nonNumericValue.value == nil)
    }

    @Test("wgrib2 client builds safe arguments with optional match pattern")
    func makeArgumentsIncludesOptionalMatchOnlyWhenProvided() throws {
        let configuration = StormSetupConfiguration(
            gribSubsetCacheRootURL: FileManager.default.temporaryDirectory,
            sampledSnapshotCacheRootURL: FileManager.default.temporaryDirectory,
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 25 * 1024 * 1024,
            wgrib2ExecutableURL: URL(fileURLWithPath: "/tmp/wgrib2"),
            wgrib2TimeoutSeconds: 15
        )
        let client = Wgrib2Client(configuration: configuration)
        let fileURL = URL(fileURLWithPath: "/tmp/sample.grib2")

        let withoutMatch = client.makeArguments(
            for: Wgrib2PointRequest(
                fileURL: fileURL,
                longitude: -104.4661,
                latitude: 39.7825,
                matchPattern: nil
            )
        )
        let withMatch = client.makeArguments(
            for: Wgrib2PointRequest(
                fileURL: fileURL,
                longitude: -104.4661,
                latitude: 39.7825,
                matchPattern: "  :CAPE:  "
            )
        )

        #expect(withoutMatch == ["/tmp/sample.grib2", "-s", "-lon", "-104.4661", "39.7825"])
        #expect(withMatch == ["/tmp/sample.grib2", "-match", ":CAPE:", "-s", "-lon", "-104.4661", "39.7825"])
    }

    @Test("process runner captures stdout and stderr for successful commands")
    func processRunnerCapturesStandardOutputAndError() async throws {
        let runner = ProcessRunner()
        let executableURL = try makeExecutableScript(
            contents: """
            #!/bin/sh
            printf 'line one\\n'
            printf 'line two\\n' 1>&2
            exit 0
            """
        )

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: [],
            timeoutSeconds: 1
        )

        #expect(result.stdout == "line one\n")
        #expect(result.stderr == "line two\n")
        #expect(result.exitCode == 0)
    }

    @Test("process runner surfaces non-zero exit status and stderr")
    func processRunnerSurfacesNonZeroExit() async throws {
        let runner = ProcessRunner()
        let executableURL = try makeExecutableScript(
            contents: """
            #!/bin/sh
            printf 'boom\\n' 1>&2
            exit 7
            """
        )

        do {
            _ = try await runner.run(
                executableURL: executableURL,
                arguments: [],
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

    @Test("process runner terminates commands that exceed the timeout")
    func processRunnerTerminatesOnTimeout() async throws {
        let runner = ProcessRunner()
        let executableURL = try makeExecutableScript(
            contents: """
            #!/usr/bin/env python3
            import sys
            import time

            sys.stderr.write("waiting for timeout\\n")
            sys.stderr.flush()
            time.sleep(5)
            """
        )

        do {
            _ = try await runner.run(
                executableURL: executableURL,
                arguments: [],
                timeoutSeconds: 2
            )
            Issue.record("Expected a timeout error.")
        } catch let error as ProcessRunnerError {
            guard case .timedOut(let timeoutSeconds, let stderr) = error else {
                Issue.record("Expected a timedOut error, got \(error).")
                return
            }

            #expect(abs(timeoutSeconds - 2) < 0.0001)
            #expect(stderr == "waiting for timeout\n")
        }
    }

    @Test("process runner drains large stdout and stderr without timing out")
    func processRunnerDrainsLargeStandardOutputAndError() async throws {
        let runner = ProcessRunner()
        let executableURL = try makeExecutableScript(
            contents: """
            #!/bin/sh
            i=1
            while [ "$i" -le 15000 ]; do
                printf 'stdout-%05d\\n' "$i"
                printf 'stderr-%05d\\n' "$i" 1>&2
                i=$((i + 1))
            done
            exit 0
            """
        )

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: [],
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

    private func makeExecutableScript(contents: String) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("storm-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let executableURL = directoryURL.appendingPathComponent("script.sh")
        guard let data = contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: executableURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        return executableURL
    }
}
