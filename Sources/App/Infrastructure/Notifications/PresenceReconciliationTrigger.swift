//
//  PresenceReconciliationTrigger.swift
//  ArcusSignal
//

import Foundation

public struct PresenceTargetingFingerprint: Equatable, Sendable {
    public let h3Cell: Int64?
    public let county: String?
    public let forecastZone: String?
    public let fireZone: String?

    public init(
        h3Cell: Int64?,
        county: String?,
        forecastZone: String?,
        fireZone: String?
    ) {
        self.h3Cell = h3Cell
        self.county = county
        self.forecastZone = forecastZone
        self.fireZone = fireZone
    }
}

public struct PresenceReconciliationState: Sendable {
    public let fingerprint: PresenceTargetingFingerprint
    public let capturedAt: Date
    public let locationAuth: LocationAuth
    public let isActive: Bool
    public let isSubscribed: Bool
    public let hasAPNsToken: Bool

    public init(
        fingerprint: PresenceTargetingFingerprint,
        capturedAt: Date,
        locationAuth: LocationAuth,
        isActive: Bool,
        isSubscribed: Bool,
        hasAPNsToken: Bool
    ) {
        self.fingerprint = fingerprint
        self.capturedAt = capturedAt
        self.locationAuth = locationAuth
        self.isActive = isActive
        self.isSubscribed = isSubscribed
        self.hasAPNsToken = hasAPNsToken
    }
}

public enum PresenceReconciliationTriggerCategory: String, Sendable, Equatable {
    case firstUsablePresence
    case movedWhileUsable
    case becameUsable
}

public struct PresenceReconciliationTrigger: Sendable, Equatable {
    public let category: PresenceReconciliationTriggerCategory

    public init(category: PresenceReconciliationTriggerCategory) {
        self.category = category
    }

    public static func decide(
        previous: PresenceReconciliationState?,
        current: PresenceReconciliationState,
        now: Date,
        freshnessPolicy: LocationFreshnessPolicy = .init()
    ) -> Self? {
        let currentUsable = isUsable(current, now: now, freshnessPolicy: freshnessPolicy)

        guard currentUsable else {
            return nil
        }

        guard let previous else {
            return Self(category: .firstUsablePresence)
        }

        let previousUsable = isUsable(previous, now: now, freshnessPolicy: freshnessPolicy)
        if !previousUsable {
            return Self(category: .becameUsable)
        }

        guard previous.fingerprint != current.fingerprint else {
            return nil
        }

        return Self(category: .movedWhileUsable)
    }

    private static func isUsable(
        _ state: PresenceReconciliationState,
        now: Date,
        freshnessPolicy: LocationFreshnessPolicy
    ) -> Bool {
        guard state.isActive, state.isSubscribed, state.hasAPNsToken else {
            return false
        }

        let freshness = freshnessPolicy.decide(
            capturedAt: state.capturedAt,
            locationAuth: state.locationAuth,
            now: now
        )
        return freshness.state != .stale
    }
}
