import Foundation

protocol StormSetupDateProviding: Sendable {
    func now() -> Date
}

struct SystemStormSetupDateProvider: StormSetupDateProviding {
    func now() -> Date {
        Date()
    }
}

protocol HrrrRunResolving: Sendable {
    func resolveRunCandidates() -> HrrrRunResolution
}

struct DefaultHrrrRunResolver: HrrrRunResolving {
    private let dateProvider: any StormSetupDateProviding
    private let lookbackHours: Int

    init(
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        lookbackHours: Int = 6
    ) {
        self.dateProvider = dateProvider
        self.lookbackHours = max(0, lookbackHours)
    }

    func resolveRunCandidates() -> HrrrRunResolution {
        let targetValidTime = dateProvider.now().stormSetupUTCRoundedDownToHour
        let candidates = (0...lookbackHours).compactMap { hoursBack -> HrrrRunCandidate? in
            guard let runTime = StormSetupUTC.calendar.date(byAdding: .hour, value: -hoursBack, to: targetValidTime) else {
                return nil
            }

            return HrrrRunCandidate(runTime: runTime, forecastHour: hoursBack)
        }

        return HrrrRunResolution(
            targetValidTime: targetValidTime,
            candidates: candidates
        )
    }
}

private extension Date {
    var stormSetupUTCRoundedDownToHour: Date {
        let components = StormSetupUTC.calendar.dateComponents([.year, .month, .day, .hour], from: self)
        guard let hour = components.hour else {
            preconditionFailure("Expected UTC hour component.")
        }

        guard let startOfHour = StormSetupUTC.calendar.date(
            from: DateComponents(
                year: components.year,
                month: components.month,
                day: components.day,
                hour: hour
            )
        ) else {
            preconditionFailure("Unable to round a date down to the UTC hour.")
        }

        return startOfHour
    }
}
