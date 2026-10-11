//
//  ext+Application.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 4/1/26.
//

import Vapor

extension Application {
    struct ArcusAPNSConfig: Sendable {
        let topic: String
    }

    private struct ArcusAPNSConfigKey: StorageKey {
        typealias Value = ArcusAPNSConfig
    }

    var arcusAPNSConfig: ArcusAPNSConfig {
        get { self.storage[ArcusAPNSConfigKey.self]! }
        set { self.storage[ArcusAPNSConfigKey.self] = newValue }
    }

    var workerScheduledJobNames: [String] {
        get { self.storage[WorkerScheduledJobNamesKey.self] ?? [] }
        set { self.storage[WorkerScheduledJobNamesKey.self] = newValue }
    }

    func recordWorkerScheduledJob(_ jobName: String) {
        workerScheduledJobNames.append(jobName)
    }

    var airQualityProvider: any AirQualityCurrentProviding {
        get { storage[AirQualityProviderKey.self]! }
        set { storage[AirQualityProviderKey.self] = newValue }
    }

    var spcMesoClient: any SPCMesoClient {
        get { storage[SPCMesoClientKey.self] ?? SPCMesoHTTPClient(http: VaporApplicationHTTPClient(application: self)) }
        set { storage[SPCMesoClientKey.self] = newValue }
    }

    var arcusSignalBuildInfo: ArcusSignalBuildInfo {
        get { storage[ArcusSignalBuildInfoKey.self]! }
        set { storage[ArcusSignalBuildInfoKey.self] = newValue }
    }
}

private struct WorkerScheduledJobNamesKey: StorageKey {
    typealias Value = [String]
}

private struct AirQualityProviderKey: StorageKey {
    typealias Value = any AirQualityCurrentProviding
}

private struct SPCMesoClientKey: StorageKey {
    typealias Value = any SPCMesoClient
}

private struct ArcusSignalBuildInfoKey: StorageKey {
    typealias Value = ArcusSignalBuildInfo
}
