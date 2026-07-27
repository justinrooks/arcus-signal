//
//  LocationFreshnessPolicy.swift
//  ArcusSignal
//
//  Created by Codex on 5/5/26.
//

import Foundation

public enum LocationFreshnessState: String, Codable, Sendable {
    case fresh
    case degraded
    case stale
}

public struct LocationFreshnessDecision: Sendable, Equatable {
    public let state: LocationFreshnessState
    public let age: TimeInterval

    public init(state: LocationFreshnessState, age: TimeInterval) {
        self.state = state
        self.age = age
    }
}

public struct LocationFreshnessPolicy: Sendable {
    private static let hour: TimeInterval = 60 * 60
    public static let hardStaleThreshold: TimeInterval = 24 * hour
    private static let whenInUseFreshThreshold: TimeInterval = 2 * hour
    private static let alwaysFreshThreshold: TimeInterval = 6 * hour

    public init() {}

    public func decide(
        capturedAt: Date,
        locationAuth: LocationAuth,
        now: Date
    ) -> LocationFreshnessDecision {
        let age = max(0, now.timeIntervalSince(capturedAt))

        guard age <= Self.hardStaleThreshold else {
            return .init(state: .stale, age: age)
        }

        let freshThreshold: TimeInterval
        switch locationAuth {
        case .whenInUse:
            freshThreshold = Self.whenInUseFreshThreshold
        case .always:
            freshThreshold = Self.alwaysFreshThreshold
        case .denied, .restricted, .notDetermined, .unknown:
            // Conservative fallback for non-granted authorization.
            return .init(state: .stale, age: age)
        }

        if age <= freshThreshold {
            return .init(state: .fresh, age: age)
        }

        return .init(state: .degraded, age: age)
    }
}
