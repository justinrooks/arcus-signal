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
        let severeTags = deriveSevereTags(for: series, of: eventKind)

        
        let title = deriveTitle(for: eventName, reason: payload.reason)
        let subTitle = deriveSubtitle(with: payload, on: device)
        let body = deriveBody(
            for: eventKind,
            tone: tone,
            reason: payload.reason,
            severeTags: severeTags
        )
        
        return .init(
            title: title,
            subTitle: subTitle,
            body: body
        )
    }
    
    private func deriveSevereTags(
        for series: ArcusSeriesModel,
        of kind: NotificationEventKind
    ) -> [String] {
        var tags: [String] = []

        switch kind {
        case .severeThunderstormWarning:
            if normalizedCategory(series.tornadoDetection) == "possible" {
                tags.append("Tornado possible")
            }

            if let damageThreat = severeThunderstormDamageThreatTag(series.thunderstormDamageThreat) {
                tags.append(damageThreat)
            }

            if let windGust = windGustTag(series.maxWindGust) {
                tags.append(windGust)
            }

            if let hailSize = hailSizeTag(series.maxHailSize) {
                tags.append(hailSize)
            }

            if let hailThreat = hazardThreatTag(series.hailThreat, noun: "severe hail") {
                tags.append(hailThreat)
            }

            if let windThreat = hazardThreatTag(series.windThreat, noun: "severe winds") {
                tags.append(windThreat)
            }

        case .tornadoWarning:
            if let detection = tornadoDetectionTag(series.tornadoDetection) {
                tags.append(detection)
            }

            if let damageThreat = tornadoDamageThreatTag(series.tornadoDamageThreat) {
                tags.append(damageThreat)
            }

        case .flashFloodWarning:
            if let detection = floodDetectionTag(series.flashFloodDetection) {
                tags.append(detection)
            }

            if let damageThreat = flashFloodDamageThreatTag(series.flashFloodDamageThreat) {
                tags.append(damageThreat)
            }

        default:
            break
        }

        return tags
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
            return "\(eventName) Update"
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
        switch payload.reason {
        case .new:
            return payload.mode == .h3 ? "Includes your location" : "For your area"
        case .update:
            return "Updated for your area"
        case .endedAllClear:
            return "No longer affecting your area"
        case .cancelInError:
            return "Cancelled for your area"
        }
    }

    private func deriveBody(
        for eventKind: NotificationEventKind,
        tone: NotificationTone,
        reason: NotificationReason,
        severeTags: [String]
    ) -> String {
        switch reason {
        case .new:
            return newAction(for: eventKind, tone: tone, severeTags: severeTags)
        case .update:
            return updateAction(for: eventKind, tone: tone, severeTags: severeTags)
        case .endedAllClear:
            return endedAction(for: eventKind)
        case .cancelInError:
            return cancelledAction(for: eventKind)
        }
    }

    // locationTarget(for:on:) function removed

    private func newAction(
        for eventKind: NotificationEventKind,
        tone: NotificationTone,
        severeTags: [String]
    ) -> String {
        switch eventKind {
        case .tornadoWarning:
            return tornadoWarningBody(reason: .new, severeTags: severeTags)
        case .tornadoWatch:
            return "Conditions are favorable for tornadoes in your area."
        case .severeThunderstormWarning:
            return severeThunderstormWarningBody(reason: .new, severeTags: severeTags)
        case .severeThunderstormWatch:
            return "Conditions are favorable for severe storms in your area."
        case .flashFloodWarning:
            return flashFloodWarningBody(reason: .new, severeTags: severeTags)
        case .blizzardWarning:
            return "Blizzard conditions expected in your area."
        case .winterStormWarning:
            return "Dangerous winter weather expected in your area."
        case .fireWarning, .redFlagWarning:
            return "Critical fire weather conditions in your area."
        case .fireWeatherWatch:
            return "Critical fire weather conditions may develop in your area."
        case .extremeFireDanger:
            return "Extreme fire danger in your area today."
        case .genericWarning:
            return genericWarningBody(for: tone)
        case .genericWatch:
            return "Weather conditions may become hazardous in your area."
        case .generic:
            return genericInformationalBody(for: tone)
        }
    }

    private func updateAction(
        for eventKind: NotificationEventKind,
        tone: NotificationTone,
        severeTags: [String]
    ) -> String {
        switch eventKind {
        case .tornadoWarning:
            return tornadoWarningBody(reason: .update, severeTags: severeTags)
        case .tornadoWatch:
            return "Tornado risk continues for your area."
        case .severeThunderstormWarning:
            return severeThunderstormWarningBody(reason: .update, severeTags: severeTags)
        case .severeThunderstormWatch:
            return "Severe storm risk continues for your area."
        case .flashFloodWarning:
            return flashFloodWarningBody(reason: .update, severeTags: severeTags)
        case .blizzardWarning:
            return "Blizzard conditions continue in your area."
        case .winterStormWarning:
            return "Dangerous winter weather continues in your area."
        case .fireWarning, .redFlagWarning:
            return "Critical fire weather conditions continue in your area."
        case .fireWeatherWatch:
            return "Fire weather risk continues for your area."
        case .extremeFireDanger:
            return "Extreme fire danger continues in your area."
        case .genericWarning:
            return "Weather alert updated for your area."
        case .genericWatch:
            return "Weather risk continues for your area."
        case .generic:
            return genericUpdateBody(for: tone)
        }
    }

    private func endedAction(for eventKind: NotificationEventKind) -> String {
        switch eventKind {
        case .tornadoWarning:
            return "This tornado warning is no longer active."
        case .tornadoWatch:
            return "This tornado watch has ended."
        case .severeThunderstormWarning:
            return "This severe thunderstorm warning is no longer active."
        case .severeThunderstormWatch:
            return "This severe thunderstorm watch has ended."
        case .flashFloodWarning:
            return "This flash flood warning is no longer active."
        case .blizzardWarning:
            return "This blizzard warning is no longer active."
        case .winterStormWarning:
            return "This winter storm warning is no longer active."
        case .fireWarning, .redFlagWarning:
            return "This red flag warning is no longer active."
        case .fireWeatherWatch:
            return "This fire weather watch has ended."
        case .extremeFireDanger:
            return "Extreme fire danger is no longer indicated for your area."
        case .genericWarning, .generic:
            return "This weather alert is no longer active."
        case .genericWatch:
            return "This weather watch has ended."
        }
    }

    private func cancelledAction(for eventKind: NotificationEventKind) -> String {
        switch eventKind {
        case .tornadoWarning:
            return "This tornado warning was cancelled by the issuer."
        case .tornadoWatch:
            return "This tornado watch was cancelled by the issuer."
        case .severeThunderstormWarning:
            return "This severe thunderstorm warning was cancelled by the issuer."
        case .severeThunderstormWatch:
            return "This severe thunderstorm watch was cancelled by the issuer."
        case .flashFloodWarning:
            return "This flash flood warning was cancelled by the issuer."
        case .blizzardWarning:
            return "This blizzard warning was cancelled by the issuer."
        case .winterStormWarning:
            return "This winter storm warning was cancelled by the issuer."
        case .fireWarning, .redFlagWarning:
            return "This red flag warning was cancelled by the issuer."
        case .fireWeatherWatch:
            return "This fire weather watch was cancelled by the issuer."
        case .extremeFireDanger, .genericWarning, .genericWatch, .generic:
            return "This weather alert was cancelled by the issuer."
        }
    }

    private func tornadoWarningBody(reason: NotificationReason, severeTags: [String]) -> String {
        if severeTags.contains("Catastrophic tornado damage possible") {
            return reason == .update
                ? "Catastrophic tornado damage remains possible in your area."
                : "Catastrophic tornado damage possible in your area."
        }

        if severeTags.contains("Considerable tornado damage possible") {
            return reason == .update
                ? "Considerable tornado damage remains possible in your area."
                : "Considerable tornado damage possible in your area."
        }

        if severeTags.contains("Observed tornado") {
            return reason == .update
                ? "Observed tornado still indicated in your area."
                : "Observed tornado in your area."
        }

        if severeTags.contains("Radar-indicated tornado") {
            return reason == .update
                ? "Radar-indicated tornado still indicated in your area."
                : "Radar-indicated tornado in your area."
        }

        return reason == .update
            ? "Tornado warning continues for your area."
            : "Tornado danger in your area."
    }

    private func severeThunderstormWarningBody(reason: NotificationReason, severeTags: [String]) -> String {
        if severeTags.contains("Tornado possible") {
            return reason == .update
                ? "Tornado possible remains in this warning."
                : "Tornado possible in this warning."
        }

        if severeTags.contains("Destructive winds possible") {
            return reason == .update
                ? "Destructive winds remain possible in your area."
                : "Destructive winds possible in your area."
        }

        if severeTags.contains("Considerable damage possible") {
            return reason == .update
                ? "Considerable damage remains possible in your area."
                : "Considerable damage possible in your area."
        }

        if let magnitude = severeThunderstormMagnitudeDetail(from: severeTags) {
            let prefix = reason == .update ? "remain possible" : "possible"
            return "\(magnitude) \(prefix) in your area."
        }

        return reason == .update
            ? "Severe thunderstorm warning continues for your area."
            : "Damaging winds or large hail possible in your area."
    }

    private func flashFloodWarningBody(reason: NotificationReason, severeTags: [String]) -> String {
        if severeTags.contains("Catastrophic flash flooding possible") {
            return reason == .update
                ? "Catastrophic flash flooding remains possible in your area."
                : "Catastrophic flash flooding possible in your area."
        }

        if severeTags.contains("Considerable flash flooding possible") {
            return reason == .update
                ? "Considerable flash flooding remains possible in your area."
                : "Considerable flash flooding possible in your area."
        }

        if severeTags.contains("Observed flooding") {
            return reason == .update
                ? "Observed flooding continues in your area."
                : "Observed flooding in your area."
        }

        if severeTags.contains("Radar-indicated flooding") {
            return reason == .update
                ? "Radar-indicated flooding continues in your area."
                : "Radar-indicated flooding in your area."
        }

        return reason == .update
            ? "Flash flood warning continues for your area."
            : "Flash flooding expected in your area."
    }

    private func severeThunderstormMagnitudeDetail(from severeTags: [String]) -> String? {
        let preferred = severeTags.filter {
            $0.hasPrefix("Wind gusts up to") || $0.hasPrefix("Hail up to")
        }

        guard preferred.isEmpty == false else {
            return nil
        }

        if preferred.count == 1 {
            return preferred[0]
        }

        let wind = preferred.first { $0.hasPrefix("Wind gusts up to") }
        let hail = preferred.first { $0.hasPrefix("Hail up to") }

        switch (wind, hail) {
        case let (wind?, hail?):
            let windValue = wind.replacingOccurrences(of: "Wind gusts up to ", with: "")
            let hailValue = hail.replacingOccurrences(of: "Hail up to ", with: "")
            return "Wind gusts up to \(windValue) and hail up to \(hailValue)"
        case let (wind?, nil):
            return wind
        case let (nil, hail?):
            return hail
        default:
            return preferred[0]
        }
    }

    private func genericWarningBody(for tone: NotificationTone) -> String {
        switch tone {
        case .critical:
            return "Dangerous weather alert for your area."
        case .high:
            return "Significant weather alert for your area."
        case .elevated:
            return "Weather alert for your area."
        case .informational:
            return "Weather information for your area."
        }
    }

    private func genericInformationalBody(for tone: NotificationTone) -> String {
        switch tone {
        case .critical:
            return "Dangerous weather conditions indicated for your area."
        case .high:
            return "Significant weather conditions indicated for your area."
        case .elevated:
            return "Weather conditions indicated for your area."
        case .informational:
            return "Weather information for your area."
        }
    }

    private func genericUpdateBody(for tone: NotificationTone) -> String {
        switch tone {
        case .critical, .high, .elevated, .informational:
            return "Weather information updated for your area."
        }
    }

    // message, conciseSecondaryDetail, warningAction, genericAction functions removed

    private func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }

        return trimmed
    }

    private func normalizedCategory(_ value: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(value) else {
            return nil
        }

        let normalized = trimmed.normalizedLowercased
        guard normalized.isEmpty == false,
              normalized != "none",
              normalized != "unknown",
              normalized != "n/a" else {
            return nil
        }

        return normalized
    }

    private func severeThunderstormDamageThreatTag(_ value: String?) -> String? {
        switch normalizedCategory(value) {
        case "considerable":
            return "Considerable damage possible"
        case "destructive":
            return "Destructive winds possible"
        default:
            return nil
        }
    }

    private func tornadoDamageThreatTag(_ value: String?) -> String? {
        switch normalizedCategory(value) {
        case "considerable":
            return "Considerable tornado damage possible"
        case "catastrophic":
            return "Catastrophic tornado damage possible"
        default:
            return nil
        }
    }

    private func flashFloodDamageThreatTag(_ value: String?) -> String? {
        switch normalizedCategory(value) {
        case "considerable":
            return "Considerable flash flooding possible"
        case "catastrophic":
            return "Catastrophic flash flooding possible"
        default:
            return nil
        }
    }

    private func tornadoDetectionTag(_ value: String?) -> String? {
        switch normalizedCategory(value) {
        case "observed":
            return "Observed tornado"
        case "radar indicated":
            return "Radar-indicated tornado"
        case "possible":
            return "Tornado possible"
        default:
            return nil
        }
    }

    private func floodDetectionTag(_ value: String?) -> String? {
        switch normalizedCategory(value) {
        case "observed":
            return "Observed flooding"
        case "radar indicated":
            return "Radar-indicated flooding"
        default:
            return nil
        }
    }

    private func hazardThreatTag(_ value: String?, noun: String) -> String? {
        switch normalizedCategory(value) {
        case "observed":
            return "Observed \(noun)"
        case "radar indicated":
            return "Radar-indicated \(noun)"
        default:
            return nil
        }
    }

    private func windGustTag(_ value: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(value) else {
            return nil
        }

        let normalized = trimmed.normalizedLowercased
        if normalized.contains("mph") {
            return "Wind gusts up to \(trimmed)"
        }

        return "Wind gusts up to \(trimmed) mph"
    }

    private func hailSizeTag(_ value: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(value) else {
            return nil
        }

        let normalized = trimmed.normalizedLowercased
        if normalized.contains("inch") || normalized.contains("in.") || normalized.contains("\"") {
            return "Hail up to \(trimmed)"
        }

        return "Hail up to \(trimmed) in"
    }
}
