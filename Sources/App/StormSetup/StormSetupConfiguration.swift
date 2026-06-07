//
//  StormSetupConfiguration.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation
import Vapor

struct StormSetupConfiguration: Sendable, Equatable {
    static let localWgrib2ExecutableURL = URL(
        fileURLWithPath: "/Users/justin/Downloads/wgrib2-3.8.0/build/install/bin/wgrib2"
    )

    static let `default` = StormSetupConfiguration(
        wgrib2ExecutableURL: localWgrib2ExecutableURL,
        wgrib2TimeoutSeconds: 15
    )

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
