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
            pressureGribSubsetCacheRootURL: FileManager.default.temporaryDirectory,
            sampledSnapshotCacheRootURL: FileManager.default.temporaryDirectory,
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 25 * 1024 * 1024,
            pressureArtifactProbeIntervalSeconds: 5 * 60,
            pressureArtifactMaxStaleAgeSeconds: 2 * 60 * 60,
            pressureArtifactDeleteGraceSeconds: 60 * 60,
            pressureArtifactCleanupIntervalSeconds: 15 * 60,
            pressureArtifactRecoveryTimeoutSeconds: 30 * 60,
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

    @Test("wgrib2 client fails fast when the configured executable is missing")
    func samplePointRejectsMissingExecutable() async throws {
        let configuration = makeConfiguration(wgrib2ExecutableURL: URL(fileURLWithPath: "/tmp/does-not-exist-wgrib2"))
        let client = Wgrib2Client(configuration: configuration)

        do {
            _ = try await client.samplePoint(
                Wgrib2PointRequest(
                    fileURL: URL(fileURLWithPath: "/tmp/sample.grib2"),
                    longitude: -104.4661,
                    latitude: 39.7825,
                    matchPattern: nil
                )
            )
            Issue.record("Expected a missing executable error.")
        } catch let error as Wgrib2ClientError {
            guard case .executableMissing(let url) = error else {
                Issue.record("Expected executableMissing, got \(error).")
                return
            }

            #expect(url.path == "/tmp/does-not-exist-wgrib2")
        }
    }

    @Test("wgrib2 client fails fast when the configured executable is not executable")
    func samplePointRejectsNonExecutableFile() async throws {
        let executableURL = try makeTemporaryFile(
            contents: "#!/bin/sh\nexit 0\n",
            permissions: 0o644
        )
        let configuration = makeConfiguration(wgrib2ExecutableURL: executableURL)
        let client = Wgrib2Client(configuration: configuration)

        do {
            _ = try await client.samplePoint(
                Wgrib2PointRequest(
                    fileURL: URL(fileURLWithPath: "/tmp/sample.grib2"),
                    longitude: -104.4661,
                    latitude: 39.7825,
                    matchPattern: nil
                )
            )
            Issue.record("Expected a non-executable error.")
        } catch let error as Wgrib2ClientError {
            guard case .executableNotExecutable(let url) = error else {
                Issue.record("Expected executableNotExecutable, got \(error).")
                return
            }

            #expect(url == executableURL)
        }
    }

    private func makeTemporaryFile(contents: String, permissions: Int) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("storm-setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let fileURL = directoryURL.appendingPathComponent("file.sh")
        guard let data = contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }

        try data.write(to: fileURL)

        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: fileURL.path
        )

        return fileURL
    }

    private func makeConfiguration(wgrib2ExecutableURL: URL) -> StormSetupConfiguration {
        StormSetupConfiguration(
            gribSubsetCacheRootURL: FileManager.default.temporaryDirectory,
            pressureGribSubsetCacheRootURL: FileManager.default.temporaryDirectory,
            sampledSnapshotCacheRootURL: FileManager.default.temporaryDirectory,
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: 25 * 1024 * 1024,
            pressureArtifactProbeIntervalSeconds: 5 * 60,
            pressureArtifactMaxStaleAgeSeconds: 2 * 60 * 60,
            pressureArtifactDeleteGraceSeconds: 60 * 60,
            pressureArtifactCleanupIntervalSeconds: 15 * 60,
            pressureArtifactRecoveryTimeoutSeconds: 30 * 60,
            wgrib2ExecutableURL: wgrib2ExecutableURL,
            wgrib2TimeoutSeconds: 15
        )
    }
}
