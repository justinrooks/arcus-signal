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
}
