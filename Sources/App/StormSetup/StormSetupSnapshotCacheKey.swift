import Foundation

enum StormSetupSnapshotCacheKeyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredSourceMetadata(String)

    var description: String {
        switch self {
        case .missingRequiredSourceMetadata(let field):
            return "Storm Setup snapshot cache key is missing required source metadata: \(field)."
        }
    }
}

struct StormSetupSnapshotCacheKey: Sendable, Hashable, Codable, Equatable {
    let h3Cell: Int64
    let model: HrrrModel
    let product: HrrrProduct
    let domain: HrrrDomain?
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let fieldSetVersion: HrrrFieldSetVersion
    let rulesVersion: StormSetupRulesVersion

    init(
        h3Cell: Int64,
        sourceMetadata: StormSetupSourceMetadata,
        rulesVersion: StormSetupRulesVersion
    ) throws {
        guard let model = sourceMetadata.model else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("model")
        }
        guard let product = sourceMetadata.product else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("product")
        }
        guard let runTime = sourceMetadata.runTime else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("runTime")
        }
        guard let forecastHour = sourceMetadata.forecastHour else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("forecastHour")
        }
        guard let validTime = sourceMetadata.validTime else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("validTime")
        }
        guard let fieldSetVersion = sourceMetadata.fieldSetVersion else {
            throw StormSetupSnapshotCacheKeyError.missingRequiredSourceMetadata("fieldSetVersion")
        }

        self.init(
            h3Cell: h3Cell,
            model: model,
            product: product,
            domain: sourceMetadata.domain,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            fieldSetVersion: fieldSetVersion,
            rulesVersion: rulesVersion
        )
    }

    init(
        h3Cell: Int64,
        model: HrrrModel,
        product: HrrrProduct,
        domain: HrrrDomain?,
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        fieldSetVersion: HrrrFieldSetVersion,
        rulesVersion: StormSetupRulesVersion
    ) {
        self.h3Cell = h3Cell
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.fieldSetVersion = fieldSetVersion
        self.rulesVersion = rulesVersion
    }

    var cacheIdentifier: String {
        pathComponents.joined(separator: "/")
    }

    var pathComponents: [String] {
        [
            "h3=\(h3Cell)",
            "model=\(model.rawValue.lowercased())",
            "product=\(product.rawValue.lowercased())",
            "domain=\(normalizedDomainComponent)",
            "run=\(Self.timestampString(for: runTime))",
            "fh=\(Self.zeroPadded(forecastHour, width: 3))",
            "valid=\(Self.timestampString(for: validTime))",
            "fields=\(fieldSetVersion.rawValue)",
            "rules=\(rulesVersion.rawValue)"
        ]
    }

    func directoryURL(rootURL: URL) -> URL {
        pathComponents.reduce(rootURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: true)
        }
    }

    func snapshotFileURL(rootURL: URL) -> URL {
        directoryURL(rootURL: rootURL).appendingPathComponent("snapshot.json", isDirectory: false)
    }

    private var normalizedDomainComponent: String {
        domain?.rawValue.lowercased() ?? "none"
    }

    private static func timestampString(for date: Date) -> String {
        let components = StormSetupUTC.calendar.dateComponents([.year, .month, .day, .hour], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day,
              let hour = components.hour else {
            preconditionFailure("Expected a UTC hour timestamp.")
        }

        return [
            zeroPadded(year, width: 4),
            zeroPadded(month, width: 2),
            zeroPadded(day, width: 2),
            "T",
            zeroPadded(hour, width: 2),
            "Z"
        ]
        .joined()
    }

    private static func zeroPadded(_ value: Int, width: Int) -> String {
        let string = String(value)
        guard string.count < width else {
            return string
        }

        return String(repeating: "0", count: width - string.count) + string
    }
}
