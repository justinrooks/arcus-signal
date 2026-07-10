import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import ArcusCore

enum StormSetupCacheKeyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredSourceMetadata(String)

    var description: String {
        switch self {
        case .missingRequiredSourceMetadata(let field):
            return "Storm Setup cache key is missing required source metadata: \(field)."
        }
    }
}

struct StormSetupCacheKey: Sendable, Hashable, Codable, Equatable {
    let model: HrrrModel
    let product: HrrrProduct
    let domain: HrrrDomain
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let bboxKey: String
    let bboxHash: String
    let fieldSetVersion: HrrrFieldSetVersion

    init(sourceMetadata: StormSetupSourceMetadata) throws {
        guard let model = sourceMetadata.model else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("model")
        }
        guard let product = sourceMetadata.product else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("product")
        }
        guard let domain = sourceMetadata.domain else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("domain")
        }
        guard let runTime = sourceMetadata.runTime else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("runTime")
        }
        guard let forecastHour = sourceMetadata.forecastHour else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("forecastHour")
        }
        guard let validTime = sourceMetadata.validTime else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("validTime")
        }
        guard let fieldSetVersion = sourceMetadata.fieldSetVersion else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("fieldSetVersion")
        }
        guard let bbox = sourceMetadata.bbox else {
            throw StormSetupCacheKeyError.missingRequiredSourceMetadata("bbox")
        }

        let bboxKey = Self.bboxKey(for: bbox)

        self.init(
            model: model,
            product: product,
            domain: domain,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            bboxKey: bboxKey,
            bboxHash: Self.sha256Hex(of: bboxKey),
            fieldSetVersion: fieldSetVersion
        )
    }

    init(
        model: HrrrModel,
        product: HrrrProduct,
        domain: HrrrDomain,
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        bboxKey: String,
        bboxHash: String,
        fieldSetVersion: HrrrFieldSetVersion
    ) {
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.bboxKey = bboxKey
        self.bboxHash = bboxHash
        self.fieldSetVersion = fieldSetVersion
    }

    var cacheIdentifier: String {
        pathComponents.joined(separator: "/")
    }

    var pathComponents: [String] {
        [
            "model=\(model.rawValue.lowercased())",
            "product=\(product.rawValue.lowercased())",
            "domain=\(domain.rawValue.lowercased())",
            "run=\(Self.timestampString(for: runTime))",
            "fh=\(Self.zeroPadded(forecastHour, width: 3))",
            "valid=\(Self.timestampString(for: validTime))",
            "fields=\(fieldSetVersion.rawValue)",
            "bbox=\(bboxHash)"
        ]
    }

    func directoryURL(rootURL: URL) -> URL {
        pathComponents.reduce(rootURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: true)
        }
    }

    func subsetFileURL(rootURL: URL) -> URL {
        directoryURL(rootURL: rootURL).appendingPathComponent("subset.grib2", isDirectory: false)
    }

    func metadataFileURL(rootURL: URL) -> URL {
        directoryURL(rootURL: rootURL).appendingPathComponent("subset.json", isDirectory: false)
    }

    private static func bboxKey(for bbox: StormSetupHrrrBoundingBox) -> String {
        [
            "leftlon=\(Self.formattedCoordinate(bbox.leftlon))",
            "rightlon=\(Self.formattedCoordinate(bbox.rightlon))",
            "toplat=\(Self.formattedCoordinate(bbox.toplat))",
            "bottomlat=\(Self.formattedCoordinate(bbox.bottomlat))"
        ]
        .joined(separator: ";")
    }

    private static func formattedCoordinate(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func timestampString(for date: Date) -> String {
        let year = StormSetupUTC.calendar.component(.year, from: date)
        let month = StormSetupUTC.calendar.component(.month, from: date)
        let day = StormSetupUTC.calendar.component(.day, from: date)
        let hour = StormSetupUTC.calendar.component(.hour, from: date)

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

    private static func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
