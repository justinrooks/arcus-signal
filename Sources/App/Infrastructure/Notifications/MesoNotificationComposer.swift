import ArcusCore
import Foundation

struct MesoNotificationComposer: Sendable {
    func buildPreviewNotification(
        for discussion: MesoscaleDiscussionPayload,
        placeLabel: String? = nil
    ) -> AlertDetails {
        let place = sanitizedPlaceLabel(placeLabel)
        return .init(
            title: "Mesoscale Discussion for \(place)",
            subTitle: watchProbabilitySubtitle(for: discussion),
            body: threatSummary(for: discussion.threats)
        )
    }

    private func watchProbabilitySubtitle(for discussion: MesoscaleDiscussionPayload) -> String {
        if let probability = discussion.watchProbability {
            return "Watch issuance chance: \(Int(probability.rounded()))%"
        }

        let sourceText = discussion.watchProbabilityText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceText.isEmpty else { return "Watch potential not specified" }
        if sourceText.localizedCaseInsensitiveCompare("unknown") == .orderedSame {
            return "Watch potential not specified"
        }
        if let probability = Double(sourceText) {
            return "Watch possible: \(Int(probability.rounded()))%"
        }
        return "Watch possible: \(sourceText)"
    }

    private func threatSummary(for threats: MesoscaleDiscussionThreats?) -> String {
        let fallback = "SPC is monitoring storms near your area. Open SkyAware for the full discussion."
        guard let threats else { return fallback }

        var concerns: [String] = []
        if threats.peakWindMPH != nil { concerns.append("damaging wind") }
        if threats.hailRangeInches != nil { concerns.append("large hail") }
        if isMeaningful(threats.tornadoStrength) { concerns.append("isolated tornadoes") }
        guard !concerns.isEmpty else { return fallback }

        let lead = concerns.count == 1
            ? "Main concern: \(concerns[0])."
            : "Main concerns: \(naturalLanguageList(concerns))."

        var details: [String] = []
        if let wind = threats.peakWindMPH {
            details.append("Gusts near \(wind) mph")
        }
        if let hail = threats.hailRangeInches {
            details.append("hail up to \(formatHailInches(hail))")
        }
        guard !details.isEmpty else { return lead }
        return "\(lead) \(details.joined(separator: "; "))."
    }

    private func sanitizedPlaceLabel(_ label: String?) -> String {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame else {
            return "your area"
        }
        return trimmed
    }

    private func isMeaningful(_ text: String?) -> Bool {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return false
        }
        return trimmed.localizedCaseInsensitiveCompare("unknown") != .orderedSame
            && trimmed.localizedCaseInsensitiveCompare("not expected") != .orderedSame
    }

    private func naturalLanguageList(_ items: [String]) -> String {
        switch items.count {
        case 0: ""
        case 1: items[0]
        case 2: "\(items[0]) and \(items[1])"
        default: "\(items.dropLast().joined(separator: ", ")), and \(items[items.count - 1])"
        }
    }

    private func formatHailInches(_ inches: Double) -> String {
        let value: String
        if inches.truncatingRemainder(dividingBy: 1) == 0 {
            value = String(Int(inches))
        } else {
            value = String(
                format: "%.1f",
                locale: Locale(identifier: "en_US_POSIX"),
                arguments: [inches]
            )
        }
        return "\(value)\""
    }
}
