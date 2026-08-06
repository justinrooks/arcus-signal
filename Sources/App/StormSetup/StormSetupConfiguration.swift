//
//  StormSetupConfiguration.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation
import Vapor

struct StormSetupConfiguration: Sendable, Equatable {
    static let localStormSetupCacheRootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("arcus-signal", isDirectory: true)
        .appendingPathComponent("storm-setup", isDirectory: true)

    static let localGribSubsetCacheRootURL = localStormSetupCacheRootURL
        .appendingPathComponent("grib-subsets", isDirectory: true)

    static let localPressureGribSubsetCacheRootURL = localStormSetupCacheRootURL
        .appendingPathComponent("pressure-grib-subsets", isDirectory: true)

    static let localSampledSnapshotCacheRootURL = localStormSetupCacheRootURL
        .appendingPathComponent("sampled-snapshots", isDirectory: true)

    static let localWgrib2ExecutableURL = URL(
        fileURLWithPath: "/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2"
    )

    static let packagedWgrib2ExecutableURL = URL(fileURLWithPath: "/usr/local/bin/wgrib2")

    static func resolved(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutableFile: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) -> StormSetupConfiguration {
        let cacheRootURL = Self.environmentFileURL(
            for: "STORM_SETUP_CACHE_ROOT",
            isDirectory: true,
            in: environment
        ) ?? localStormSetupCacheRootURL

        let wgrib2ExecutableURL = Self.environmentFileURL(
            for: "STORM_SETUP_WGRIB2_PATH",
            isDirectory: false,
            in: environment
        ) ?? Self.defaultWgrib2ExecutableURL(isExecutableFile: isExecutableFile)

        let gribSubsetMaximumByteCount = Self.environmentInt(
            for: "STORM_SETUP_GRIB_MAX_BYTES",
            in: environment
        ) ?? 200 * 1024 * 1024

        let pressureArtifactProbeIntervalSeconds = Self.environmentTimeInterval(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_PROBE_INTERVAL_SECONDS",
            in: environment
        ) ?? 5 * 60

        let pressureArtifactMaxStaleAgeSeconds = Self.environmentTimeInterval(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_MAX_STALE_AGE_SECONDS",
            in: environment
        ) ?? 2 * 60 * 60

        let pressureArtifactDeleteGraceSeconds = Self.environmentTimeInterval(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_DELETE_GRACE_SECONDS",
            in: environment
        ) ?? 60 * 60

        let pressureArtifactCleanupIntervalSeconds = Self.environmentTimeInterval(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_CLEANUP_INTERVAL_SECONDS",
            in: environment
        ) ?? 15 * 60

        let pressureArtifactRecoveryTimeoutSeconds = Self.environmentPositiveTimeInterval(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_RECOVERY_TIMEOUT_SECONDS",
            defaultValue: 30 * 60,
            in: environment
        )

        let pressureArtifactHTTPTimeoutSeconds = Self.environmentPositiveTimeIntervalOrDefault(
            for: "STORM_SETUP_PRESSURE_ARTIFACT_HTTP_TIMEOUT_SECONDS",
            defaultValue: 30,
            in: environment
        )

        let wgrib2TimeoutSeconds = Self.environmentTimeInterval(
            for: "STORM_SETUP_WGRIB2_TIMEOUT_SECONDS",
            in: environment
        ) ?? 15

        let anvilProfileAnalysisBaseURL = Self.environmentURL(
            for: "ANVIL_PROFILE_ANALYSIS_BASE_URL",
            in: environment
        )
        let anvilProfileAnalysisTimeoutSeconds = Self.environmentTimeInterval(
            for: "ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS",
            in: environment
        )

        return StormSetupConfiguration(
            gribSubsetCacheRootURL: cacheRootURL.appendingPathComponent(
                "grib-subsets",
                isDirectory: true
            ),
            pressureGribSubsetCacheRootURL: cacheRootURL.appendingPathComponent(
                "pressure-grib-subsets",
                isDirectory: true
            ),
            sampledSnapshotCacheRootURL: cacheRootURL.appendingPathComponent(
                "sampled-snapshots",
                isDirectory: true
            ),
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: gribSubsetMaximumByteCount,
            pressureArtifactProbeIntervalSeconds: pressureArtifactProbeIntervalSeconds,
            pressureArtifactMaxStaleAgeSeconds: pressureArtifactMaxStaleAgeSeconds,
            pressureArtifactDeleteGraceSeconds: pressureArtifactDeleteGraceSeconds,
            pressureArtifactCleanupIntervalSeconds: pressureArtifactCleanupIntervalSeconds,
            pressureArtifactRecoveryTimeoutSeconds: pressureArtifactRecoveryTimeoutSeconds,
            pressureArtifactHTTPTimeoutSeconds: pressureArtifactHTTPTimeoutSeconds,
            wgrib2ExecutableURL: wgrib2ExecutableURL,
            wgrib2TimeoutSeconds: wgrib2TimeoutSeconds,
            anvilProfileAnalysisBaseURL: anvilProfileAnalysisBaseURL,
            anvilProfileAnalysisTimeoutSeconds: anvilProfileAnalysisTimeoutSeconds
        )
    }

    static let `default` = StormSetupConfiguration(
        gribSubsetCacheRootURL: localGribSubsetCacheRootURL,
        pressureGribSubsetCacheRootURL: localPressureGribSubsetCacheRootURL,
        sampledSnapshotCacheRootURL: localSampledSnapshotCacheRootURL,
        gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
        gribSubsetMaximumByteCount: 200 * 1024 * 1024,
        pressureArtifactProbeIntervalSeconds: 5 * 60,
        pressureArtifactMaxStaleAgeSeconds: 2 * 60 * 60,
        pressureArtifactDeleteGraceSeconds: 60 * 60,
        pressureArtifactCleanupIntervalSeconds: 15 * 60,
        pressureArtifactRecoveryTimeoutSeconds: 30 * 60,
        pressureArtifactHTTPTimeoutSeconds: 30,
        wgrib2ExecutableURL: localWgrib2ExecutableURL,
        wgrib2TimeoutSeconds: 15,
        anvilProfileAnalysisBaseURL: nil,
        anvilProfileAnalysisTimeoutSeconds: nil
    )

    let gribSubsetCacheRootURL: URL
    let pressureGribSubsetCacheRootURL: URL
    let sampledSnapshotCacheRootURL: URL
    let gribSubsetCacheRetentionSeconds: TimeInterval
    let gribSubsetMaximumByteCount: Int
    let pressureArtifactProbeIntervalSeconds: TimeInterval
    let pressureArtifactMaxStaleAgeSeconds: TimeInterval
    let pressureArtifactDeleteGraceSeconds: TimeInterval
    let pressureArtifactCleanupIntervalSeconds: TimeInterval
    let pressureArtifactRecoveryTimeoutSeconds: TimeInterval
    let pressureArtifactHTTPTimeoutSeconds: TimeInterval
    let wgrib2ExecutableURL: URL
    let wgrib2TimeoutSeconds: TimeInterval
    let anvilProfileAnalysisBaseURL: URL?
    let anvilProfileAnalysisTimeoutSeconds: TimeInterval?

    init(
        gribSubsetCacheRootURL: URL,
        pressureGribSubsetCacheRootURL: URL,
        sampledSnapshotCacheRootURL: URL,
        gribSubsetCacheRetentionSeconds: TimeInterval,
        gribSubsetMaximumByteCount: Int,
        pressureArtifactProbeIntervalSeconds: TimeInterval,
        pressureArtifactMaxStaleAgeSeconds: TimeInterval,
        pressureArtifactDeleteGraceSeconds: TimeInterval,
        pressureArtifactCleanupIntervalSeconds: TimeInterval,
        pressureArtifactRecoveryTimeoutSeconds: TimeInterval,
        pressureArtifactHTTPTimeoutSeconds: TimeInterval = 30,
        wgrib2ExecutableURL: URL,
        wgrib2TimeoutSeconds: TimeInterval,
        anvilProfileAnalysisBaseURL: URL? = nil,
        anvilProfileAnalysisTimeoutSeconds: TimeInterval? = nil
    ) {
        self.gribSubsetCacheRootURL = gribSubsetCacheRootURL
        self.pressureGribSubsetCacheRootURL = pressureGribSubsetCacheRootURL
        self.sampledSnapshotCacheRootURL = sampledSnapshotCacheRootURL
        self.gribSubsetCacheRetentionSeconds = gribSubsetCacheRetentionSeconds
        self.gribSubsetMaximumByteCount = gribSubsetMaximumByteCount
        self.pressureArtifactProbeIntervalSeconds = pressureArtifactProbeIntervalSeconds
        self.pressureArtifactMaxStaleAgeSeconds = pressureArtifactMaxStaleAgeSeconds
        self.pressureArtifactDeleteGraceSeconds = pressureArtifactDeleteGraceSeconds
        self.pressureArtifactCleanupIntervalSeconds = pressureArtifactCleanupIntervalSeconds
        self.pressureArtifactRecoveryTimeoutSeconds = pressureArtifactRecoveryTimeoutSeconds
        self.pressureArtifactHTTPTimeoutSeconds = pressureArtifactHTTPTimeoutSeconds
        self.wgrib2ExecutableURL = wgrib2ExecutableURL
        self.wgrib2TimeoutSeconds = wgrib2TimeoutSeconds
        self.anvilProfileAnalysisBaseURL = anvilProfileAnalysisBaseURL
        self.anvilProfileAnalysisTimeoutSeconds = anvilProfileAnalysisTimeoutSeconds
    }

    func makeWgrib2Client(runner: ProcessRunner = ProcessRunner()) -> Wgrib2Client {
        Wgrib2Client(configuration: self, runner: runner)
    }

    func makeAnvilProfileClient(httpClient: any HTTPClient) throws -> any AnvilProfileClient {
        guard let baseURL = anvilProfileAnalysisBaseURL,
              let timeoutSeconds = anvilProfileAnalysisTimeoutSeconds else {
            throw AnvilProfileClientError.missingConfiguration(
                missingKeys: [
                    anvilProfileAnalysisBaseURL == nil ? "ANVIL_PROFILE_ANALYSIS_BASE_URL" : nil,
                    anvilProfileAnalysisTimeoutSeconds == nil ? "ANVIL_PROFILE_ANALYSIS_TIMEOUT_SECONDS" : nil
                ].compactMap { $0 }
            )
        }

        return DefaultAnvilProfileClient(
            baseURL: baseURL,
            timeoutSeconds: timeoutSeconds,
            httpClient: httpClient
        )
    }

    private static func environmentFileURL(
        for key: String,
        isDirectory: Bool,
        in environment: [String: String]
    ) -> URL? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: rawValue, isDirectory: isDirectory)
    }

    private static func defaultWgrib2ExecutableURL(
        isExecutableFile: (String) -> Bool
    ) -> URL {
        if isExecutableFile(packagedWgrib2ExecutableURL.path) {
            return packagedWgrib2ExecutableURL
        }

        return localWgrib2ExecutableURL
    }

    private static func environmentInt(
        for key: String,
        in environment: [String: String]
    ) -> Int? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return Int(rawValue)
    }

    private static func environmentTimeInterval(
        for key: String,
        in environment: [String: String]
    ) -> TimeInterval? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return TimeInterval(rawValue)
    }

    private static func environmentPositiveTimeInterval(
        for key: String,
        defaultValue: TimeInterval,
        in environment: [String: String]
    ) -> TimeInterval {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return defaultValue
        }

        guard let parsed = TimeInterval(rawValue), parsed > 0 else {
            return 1
        }

        return parsed
    }

    private static func environmentPositiveTimeIntervalOrDefault(
        for key: String,
        defaultValue: TimeInterval,
        in environment: [String: String]
    ) -> TimeInterval {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let parsed = TimeInterval(rawValue),
              parsed.isFinite,
              parsed > 0,
              isRequestTimeoutRepresentable(parsed) else {
            return defaultValue
        }

        return parsed
    }

    private static func isRequestTimeoutRepresentable(_ timeoutSeconds: TimeInterval) -> Bool {
        let nanoseconds = timeoutSeconds * 1_000_000_000
        return nanoseconds.isFinite && nanoseconds >= 1 && nanoseconds < Double(Int64.max)
    }

    private static func environmentURL(
        for key: String,
        in environment: [String: String]
    ) -> URL? {
        guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        return URL(string: rawValue)
    }
}

private struct StormSetupConfigurationKey: StorageKey {
    typealias Value = StormSetupConfiguration
}

extension Application {
    var stormSetupConfiguration: StormSetupConfiguration {
        get {
            storage[StormSetupConfigurationKey.self] ?? .resolved()
        }
        set {
            storage[StormSetupConfigurationKey.self] = newValue
        }
    }

    var stormSetupWgrib2Client: Wgrib2Client {
        stormSetupConfiguration.makeWgrib2Client()
    }
}
