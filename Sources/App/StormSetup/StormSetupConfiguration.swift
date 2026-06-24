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

    static let localPressureGribRawCacheRootURL = localStormSetupCacheRootURL
        .appendingPathComponent("pressure-grib-raw", isDirectory: true)

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
        ) ?? 50 * 1024 * 1024

        let pressureGribRawMaximumByteCount = Self.environmentInt(
            for: "STORM_SETUP_PRESSURE_GRIB_MAX_BYTES",
            in: environment
        ) ?? 150 * 1024 * 1024

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
            pressureGribRawCacheRootURL: cacheRootURL.appendingPathComponent(
                "pressure-grib-raw",
                isDirectory: true
            ),
            sampledSnapshotCacheRootURL: cacheRootURL.appendingPathComponent(
                "sampled-snapshots",
                isDirectory: true
            ),
            gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
            gribSubsetMaximumByteCount: gribSubsetMaximumByteCount,
            pressureGribRawMaximumByteCount: pressureGribRawMaximumByteCount,
            wgrib2ExecutableURL: wgrib2ExecutableURL,
            wgrib2TimeoutSeconds: wgrib2TimeoutSeconds,
            anvilProfileAnalysisBaseURL: anvilProfileAnalysisBaseURL,
            anvilProfileAnalysisTimeoutSeconds: anvilProfileAnalysisTimeoutSeconds
        )
    }

    static let `default` = StormSetupConfiguration(
        gribSubsetCacheRootURL: localGribSubsetCacheRootURL,
        pressureGribSubsetCacheRootURL: localPressureGribSubsetCacheRootURL,
        pressureGribRawCacheRootURL: localPressureGribRawCacheRootURL,
        sampledSnapshotCacheRootURL: localSampledSnapshotCacheRootURL,
        gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
        gribSubsetMaximumByteCount: 30 * 1024 * 1024,
        pressureGribRawMaximumByteCount: 150 * 1024 * 1024,
        wgrib2ExecutableURL: localWgrib2ExecutableURL,
        wgrib2TimeoutSeconds: 15,
        anvilProfileAnalysisBaseURL: nil,
        anvilProfileAnalysisTimeoutSeconds: nil
    )

    let gribSubsetCacheRootURL: URL
    let pressureGribSubsetCacheRootURL: URL
    let pressureGribRawCacheRootURL: URL
    let sampledSnapshotCacheRootURL: URL
    let gribSubsetCacheRetentionSeconds: TimeInterval
    let gribSubsetMaximumByteCount: Int
    let pressureGribRawMaximumByteCount: Int
    let wgrib2ExecutableURL: URL
    let wgrib2TimeoutSeconds: TimeInterval
    let anvilProfileAnalysisBaseURL: URL?
    let anvilProfileAnalysisTimeoutSeconds: TimeInterval?

    init(
        gribSubsetCacheRootURL: URL,
        pressureGribSubsetCacheRootURL: URL,
        pressureGribRawCacheRootURL: URL,
        sampledSnapshotCacheRootURL: URL,
        gribSubsetCacheRetentionSeconds: TimeInterval,
        gribSubsetMaximumByteCount: Int,
        pressureGribRawMaximumByteCount: Int,
        wgrib2ExecutableURL: URL,
        wgrib2TimeoutSeconds: TimeInterval,
        anvilProfileAnalysisBaseURL: URL? = nil,
        anvilProfileAnalysisTimeoutSeconds: TimeInterval? = nil
    ) {
        self.gribSubsetCacheRootURL = gribSubsetCacheRootURL
        self.pressureGribSubsetCacheRootURL = pressureGribSubsetCacheRootURL
        self.pressureGribRawCacheRootURL = pressureGribRawCacheRootURL
        self.sampledSnapshotCacheRootURL = sampledSnapshotCacheRootURL
        self.gribSubsetCacheRetentionSeconds = gribSubsetCacheRetentionSeconds
        self.gribSubsetMaximumByteCount = gribSubsetMaximumByteCount
        self.pressureGribRawMaximumByteCount = pressureGribRawMaximumByteCount
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
