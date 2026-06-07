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

    static let localSampledSnapshotCacheRootURL = localStormSetupCacheRootURL
        .appendingPathComponent("sampled-snapshots", isDirectory: true)

    static let localWgrib2ExecutableURL = URL(
        fileURLWithPath: "/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2"
    )

    static let `default` = StormSetupConfiguration(
        gribSubsetCacheRootURL: localGribSubsetCacheRootURL,
        sampledSnapshotCacheRootURL: localSampledSnapshotCacheRootURL,
        gribSubsetCacheRetentionSeconds: 12 * 60 * 60,
        gribSubsetMaximumByteCount: 25 * 1024 * 1024,
        wgrib2ExecutableURL: localWgrib2ExecutableURL,
        wgrib2TimeoutSeconds: 15
    )

    let gribSubsetCacheRootURL: URL
    let sampledSnapshotCacheRootURL: URL
    let gribSubsetCacheRetentionSeconds: TimeInterval
    let gribSubsetMaximumByteCount: Int
    let wgrib2ExecutableURL: URL
    let wgrib2TimeoutSeconds: TimeInterval

    func makeWgrib2Client(runner: ProcessRunner = ProcessRunner()) -> Wgrib2Client {
        Wgrib2Client(configuration: self, runner: runner)
    }
}

private struct StormSetupConfigurationKey: StorageKey {
    typealias Value = StormSetupConfiguration
}

extension Application {
    var stormSetupConfiguration: StormSetupConfiguration {
        get {
            storage[StormSetupConfigurationKey.self] ?? .default
        }
        set {
            storage[StormSetupConfigurationKey.self] = newValue
        }
    }

    var stormSetupWgrib2Client: Wgrib2Client {
        stormSetupConfiguration.makeWgrib2Client()
    }
}
