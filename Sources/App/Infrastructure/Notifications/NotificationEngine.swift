//
//  NotificationEngine.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/13/26.
//

import Foundation

private enum NotificationTone: Codable, CaseIterable {
    case critical
    case high
    case elevated
    case informational
}

private enum NotificationEventKind: Sendable {
    case tornadoWarning
    case tornadoWatch
    case severeThunderstormWarning
    case severeThunderstormWatch
    case flashFloodWarning
    case blizzardWarning
    case winterStormWarning
    case fireWarning
    case fireWeatherWatch
    case extremeFireDanger
    case redFlagWarning
    case genericWarning
    case genericWatch
    case generic

    init(eventName: String) {
        let normalized = eventName.normalizedLowercased

        switch normalized {
        case let value where value.contains("tornado warning"):
            self = .tornadoWarning
        case let value where value.contains("tornado watch"):
            self = .tornadoWatch
        case let value where value.contains("severe thunderstorm warning"):
            self = .severeThunderstormWarning
        case let value where value.contains("severe thunderstorm watch"):
            self = .severeThunderstormWatch
        case let value where value.contains("flash flood warning"):
            self = .flashFloodWarning
        case let value where value.contains("blizzard warning"):
            self = .blizzardWarning
        case let value where value.contains("winter storm warning"):
            self = .winterStormWarning
        case let value where value.contains("fire weather watch"):
            self = .fireWeatherWatch
        case let value where value.contains("extreme fire danger"):
            self = .extremeFireDanger
        case let value where value.contains("red flag warning"):
            self = .redFlagWarning
        case let value where value.contains("fire") && value.contains("warning"):
            self = .fireWarning
        case let value where value.contains("warning"):
            self = .genericWarning
        case let value where value.contains("watch"):
            self = .genericWatch
        default:
            self = .generic
        }
    }
}

struct NotificationEngine: Sendable {
    func buildNotification(
        for series: ArcusSeriesModel,
        with payload: NotificationSendJobPayload,
        on device: NotificationCandidate
    ) -> AlertDetails {
        let eventName = deriveEventName(for: series)
        let tone = deriveTone(for: series)
        let eventKind = NotificationEventKind(eventName: eventName)

        return .init(
            title: deriveTitle(for: eventName, reason: payload.reason),
            subTitle: deriveSubtitle(with: payload, on: device),
            body: deriveBody(for: eventKind, tone: tone, reason: payload.reason)
        )
    }

    private func deriveTone(for series: ArcusSeriesModel) -> NotificationTone {
        let severity = series.severity.normalizedLowercased
        let urgency = series.urgency.normalizedLowercased
        let certainty = series.certainty.normalizedLowercased

        if severity == "extreme" && urgency == "immediate" {
            return .critical
        }

        if severity == "severe"
            && (urgency == "immediate" || urgency == "expected")
            && (certainty == "observed" || certainty == "likely" || certainty == "possible") {
            return .high
        }

        if severity == "moderate"
            || urgency == "expected"
            || certainty == "possible" {
            return .elevated
        }

        if severity == "minor" || severity == "unknown" {
            return .informational
        }

        return .elevated
    }

    private func deriveEventName(for series: ArcusSeriesModel) -> String {
        let candidates = [series.event, series.title, series.headline]

        for candidate in candidates {
            guard let trimmed = trimmedNonEmpty(candidate) else { continue }
            return trimmed
        }

        return "Weather Alert"
    }

    private func deriveTitle(for eventName: String, reason: NotificationReason) -> String {
        switch reason {
        case .new:
            return eventName
        case .update:
            return "\(eventName)"
        case .endedAllClear:
            return "\(eventName) Ended"
        case .cancelInError:
            return "\(eventName) Cancelled"
        }
    }

    private func deriveSubtitle(
        with payload: NotificationSendJobPayload,
        on device: NotificationCandidate
    ) -> String {
        let location = locationTarget(for: payload.mode, on: device)

        switch payload.reason {
        case .new:
            if payload.mode == .h3 {
                return "At \(location)"
            }

            return "For \(location)"
        case .update:
            return "Updated for \(location)"
        case .endedAllClear:
            return "No longer affecting \(location)"
        case .cancelInError:
            return "Cancelled for \(location)"
        }
    }

    private func deriveBody(
        for eventKind: NotificationEventKind,
        tone: NotificationTone,
        reason: NotificationReason
    ) -> String {
        let action: String

        switch reason {
        case .new:
            action = newAction(for: eventKind, tone: tone)
        case .update:
            action = updateAction(for: eventKind, tone: tone)
        case .endedAllClear:
            action = "This alert is no longer active."
        case .cancelInError:
            action = "This alert was cancelled by the issuer."
        }

        return "\(action) Tap for details."
    }

    private func locationTarget(
        for mode: NotificationTargetMode,
        on device: NotificationCandidate
    ) -> String {
        switch mode {
        case .h3:
            return "your location"
        case .ugc:
            if let countyLabel = trimmedNonEmpty(device.countyLabel) {
                return countyLabel
            }
            if let fireZoneLabel = trimmedNonEmpty(device.fireZoneLabel) {
                return fireZoneLabel
            }
            return "your area"
        }
    }

    private func newAction(
        for eventKind: NotificationEventKind,
        tone: NotificationTone
    ) -> String {
        switch eventKind {
        case .tornadoWarning:
            return "Take shelter now."
        case .tornadoWatch:
            return "Conditions are favorable for tornadoes. Stay ready to act."
        case .severeThunderstormWarning:
            return "Move indoors and protect yourself from dangerous weather."
        case .severeThunderstormWatch:
            return "Conditions are favorable for severe storms. Stay ready to act."
        case .flashFloodWarning:
            return "Move to higher ground and avoid flooded roads."
        case .blizzardWarning:
            return "Travel may become dangerous very quickly."
        case .winterStormWarning:
            return "Travel conditions may deteriorate quickly."
        case .fireWarning:
            return "Be ready to act quickly if fire conditions worsen."
        case .fireWeatherWatch:
            return "Fire conditions may develop. Avoid anything that can start a fire."
        case .extremeFireDanger, .redFlagWarning:
            return "Fire danger is high. Avoid anything that can start a fire."
        case .genericWarning:
            return warningAction(for: tone)
        case .genericWatch:
            return "Conditions are favorable. Stay ready."
        case .generic:
            return genericAction(for: tone)
        }
    }

    private func updateAction(
        for eventKind: NotificationEventKind,
        tone: NotificationTone
    ) -> String {
        switch eventKind {
        case .tornadoWarning:
            return "Take shelter now if threatened."
        case .tornadoWatch, .severeThunderstormWatch:
            return "Stay ready to act quickly."
        case .severeThunderstormWarning:
            return "Stay indoors and protect yourself from dangerous weather."
        case .flashFloodWarning:
            return "Avoid flooded roads and low-lying areas."
        case .blizzardWarning, .winterStormWarning:
            return "Travel conditions may still worsen."
        case .fireWarning, .fireWeatherWatch, .extremeFireDanger, .redFlagWarning:
            return "Fire danger may still increase quickly."
        case .genericWarning:
            return warningAction(for: tone)
        case .genericWatch:
            return "Stay ready for changing conditions."
        case .generic:
            return genericAction(for: tone)
        }
    }

    private func warningAction(for tone: NotificationTone) -> String {
        switch tone {
        case .critical:
            return "Take action now."
        case .high:
            return "Be ready to act quickly."
        case .elevated:
            return "Use caution and stay alert."
        case .informational:
            return "Stay aware of changing conditions."
        }
    }

    private func genericAction(for tone: NotificationTone) -> String {
        switch tone {
        case .critical:
            return "Take action now."
        case .high:
            return "Stay alert and be ready to act quickly."
        case .elevated:
            return "Stay alert."
        case .informational:
            return "Monitor conditions."
        }
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        return trimmed
    }
}
