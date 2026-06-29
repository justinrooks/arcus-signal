import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

struct HrrrPressureSubsetGribCacheResult: Sendable {
    let source: StormSetupSourceMetadata
    let localFileURL: URL
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
    let expiresAt: Date
    let cacheHit: Bool

    var localFilePath: String {
        localFileURL.path
    }
}

struct HrrrPressureSubsetGribCacheRecord: Codable, Sendable {
    let key: HrrrPressureSubsetGribCacheKey
    let source: StormSetupSourceMetadata
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
    let expiresAt: Date
}

enum HrrrPressureSubsetGribCacheError: Error, Sendable, CustomStringConvertible {
    case responseTooLarge(source: StormSetupSourceMetadata, byteCount: Int, maximumByteCount: Int)
    case invalidCachedFile(source: StormSetupSourceMetadata, reason: String)
    case checksumMismatch(source: StormSetupSourceMetadata, expected: String, actual: String)
    case unableToCreateDirectory(path: URL, reason: String)
    case unableToWriteCache(path: URL, reason: String)

    var description: String {
        switch self {
        case .responseTooLarge(let source, let byteCount, let maximumByteCount):
            return "HRRR pressure subset download was \(byteCount) bytes, exceeding the cache limit of \(maximumByteCount) bytes for source metadata: \(source)."
        case .invalidCachedFile(let source, let reason):
            return "Cached HRRR pressure subset is invalid for source metadata: \(source). Reason: \(reason)"
        case .checksumMismatch(let source, let expected, let actual):
            return "Cached HRRR pressure subset checksum mismatch for source metadata: \(source). Expected \(expected), got \(actual)."
        case .unableToCreateDirectory(let path, let reason):
            return "Unable to create HRRR pressure subset cache directory at \(path.path): \(reason)"
        case .unableToWriteCache(let path, let reason):
            return "Unable to write HRRR pressure subset cache at \(path.path): \(reason)"
        }
    }
}

enum HrrrPressureSubsetGribCacheKeyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredSourceMetadata(String)
    case unsupportedSourceKind(HrrrSourceKind)

    var description: String {
        switch self {
        case .missingRequiredSourceMetadata(let field):
            return "HRRR pressure subset cache key is missing required source metadata: \(field)."
        case .unsupportedSourceKind(let sourceKind):
            return "HRRR pressure subset cache key only supports direct-object sources, not \(sourceKind.rawValue)."
        }
    }
}

struct HrrrPressureSubsetGribCacheKey: Sendable, Hashable, Codable, Equatable {
    let sourceKind: HrrrSourceKind
    let model: HrrrModel
    let product: HrrrProduct
    let domain: HrrrDomain
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let fieldSetVersion: HrrrFieldSetVersion
    let sourceURL: URL
    let rangeIdentity: [String]

    init(sourceMetadata: StormSetupSourceMetadata, byteRangePlan: HrrrGribByteRangePlan) throws {
        guard sourceMetadata.sourceKind == .directObject else {
            throw HrrrPressureSubsetGribCacheKeyError.unsupportedSourceKind(sourceMetadata.sourceKind)
        }
        guard let model = sourceMetadata.model else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("model")
        }
        guard let product = sourceMetadata.product else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("product")
        }
        guard let domain = sourceMetadata.domain else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("domain")
        }
        guard let runTime = sourceMetadata.runTime else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("runTime")
        }
        guard let forecastHour = sourceMetadata.forecastHour else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("forecastHour")
        }
        guard let validTime = sourceMetadata.validTime else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("validTime")
        }
        guard let fieldSetVersion = sourceMetadata.fieldSetVersion else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("fieldSetVersion")
        }
        guard let sourceURL = sourceMetadata.primaryDownloadURL else {
            throw HrrrPressureSubsetGribCacheKeyError.missingRequiredSourceMetadata("primaryDownloadURL")
        }

        self.init(
            sourceKind: sourceMetadata.sourceKind,
            model: model,
            product: product,
            domain: domain,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            fieldSetVersion: fieldSetVersion,
            sourceURL: sourceURL,
            rangeIdentity: Self.rangeIdentity(from: byteRangePlan)
        )
    }

    init(
        sourceKind: HrrrSourceKind,
        model: HrrrModel,
        product: HrrrProduct,
        domain: HrrrDomain,
        runTime: Date,
        forecastHour: Int,
        validTime: Date,
        fieldSetVersion: HrrrFieldSetVersion,
        sourceURL: URL,
        rangeIdentity: [String]
    ) {
        self.sourceKind = sourceKind
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.fieldSetVersion = fieldSetVersion
        self.sourceURL = sourceURL
        self.rangeIdentity = rangeIdentity
    }

    var cacheIdentifier: String {
        pathComponents.joined(separator: "/")
    }

    var pathComponents: [String] {
        [
            "source=pressure-byte-range",
            "model=\(model.rawValue.lowercased())",
            "product=\(product.rawValue.lowercased())",
            "domain=\(domain.rawValue.lowercased())",
            "run=\(Self.timestampString(for: runTime))",
            "fh=\(Self.zeroPadded(forecastHour, width: 3))",
            "valid=\(Self.timestampString(for: validTime))",
            "fields=\(fieldSetVersion.rawValue)",
            "source-url=\(Self.sha256Hex(of: sourceURL.absoluteString))",
            "ranges=\(Self.sha256Hex(of: rangeIdentity.joined(separator: "|")))"
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

    private static func rangeIdentity(from plan: HrrrGribByteRangePlan) -> [String] {
        plan.ranges.map { range in
            [
                "idx=\(range.inventoryIndex)",
                "msg=\(range.selectedMessage.record.messageNumber)",
                "start=\(range.startOffset)",
                "end=\(range.endOffset.map(String.init) ?? "open")",
                "var=\(range.selectedMessage.variable.rawValue)",
                "level=\(range.selectedMessage.pressureLevel.pressureMb)",
                "range=\(range.httpRangeHeaderValue)"
            ]
            .joined(separator: ";")
        }
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

actor HrrrPressureSubsetGribCache {
    private let downloader: HrrrPressureByteRangeDownloader
    private let fileManager: FileManager
    private let rootURL: URL
    private let dateProvider: any StormSetupDateProviding
    private let retentionDuration: TimeInterval
    private let maximumByteCount: Int
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init(
        httpClient: any HTTPClient,
        fileManager: FileManager = .default,
        rootURL: URL = StormSetupConfiguration.localPressureGribSubsetCacheRootURL,
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        retentionDuration: TimeInterval = StormSetupConfiguration.default.gribSubsetCacheRetentionSeconds,
        maximumByteCount: Int = StormSetupConfiguration.default.gribSubsetMaximumByteCount
    ) {
        self.downloader = HrrrPressureByteRangeDownloader(httpClient: httpClient)
        self.fileManager = fileManager
        self.rootURL = rootURL
        self.dateProvider = dateProvider
        self.retentionDuration = retentionDuration
        self.maximumByteCount = maximumByteCount

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.jsonEncoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.jsonDecoder = decoder
    }

    func loadOrFetch(
        sourceMetadata: StormSetupSourceMetadata,
        byteRangePlan: HrrrGribByteRangePlan
    ) async throws -> HrrrPressureSubsetGribCacheResult {
        let key = try HrrrPressureSubsetGribCacheKey(sourceMetadata: sourceMetadata, byteRangePlan: byteRangePlan)
        let fileURL = key.subsetFileURL(rootURL: rootURL)
        let metadataURL = key.metadataFileURL(rootURL: rootURL)
        let now = dateProvider.now()

        if let record = loadValidRecord(key: key, fileURL: fileURL, metadataURL: metadataURL, now: now) {
            return HrrrPressureSubsetGribCacheResult(
                source: record.source,
                localFileURL: fileURL,
                byteSize: record.byteSize,
                checksumSHA256: record.checksumSHA256,
                fetchedAt: record.fetchedAt,
                expiresAt: record.expiresAt,
                cacheHit: true
            )
        }

        do {
            try fileManager.createDirectory(at: key.directoryURL(rootURL: rootURL), withIntermediateDirectories: true)
        } catch {
            throw HrrrPressureSubsetGribCacheError.unableToCreateDirectory(
                path: key.directoryURL(rootURL: rootURL),
                reason: String(describing: error)
            )
        }

        let downloadResult = try await downloader.download(
            sourceMetadata: sourceMetadata,
            byteRangePlan: byteRangePlan
        )

        guard downloadResult.byteSize <= maximumByteCount else {
            throw HrrrPressureSubsetGribCacheError.responseTooLarge(
                source: sourceMetadata,
                byteCount: Int(downloadResult.byteSize),
                maximumByteCount: maximumByteCount
            )
        }

        let expiresAt = now.addingTimeInterval(retentionDuration)
        let record = HrrrPressureSubsetGribCacheRecord(
            key: key,
            source: sourceMetadata,
            byteSize: downloadResult.byteSize,
            checksumSHA256: downloadResult.checksumSHA256,
            fetchedAt: now,
            expiresAt: expiresAt
        )

        do {
            try downloadResult.data.write(to: fileURL, options: [.atomic])
            try write(record: record, to: metadataURL)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: metadataURL)
            throw HrrrPressureSubsetGribCacheError.unableToWriteCache(path: fileURL, reason: String(describing: error))
        }

        return HrrrPressureSubsetGribCacheResult(
            source: sourceMetadata,
            localFileURL: fileURL,
            byteSize: downloadResult.byteSize,
            checksumSHA256: downloadResult.checksumSHA256,
            fetchedAt: now,
            expiresAt: expiresAt,
            cacheHit: false
        )
    }

    func invalidate(
        sourceMetadata: StormSetupSourceMetadata,
        byteRangePlan: HrrrGribByteRangePlan
    ) async {
        guard let key = try? HrrrPressureSubsetGribCacheKey(sourceMetadata: sourceMetadata, byteRangePlan: byteRangePlan) else {
            return
        }

        invalidate(
            fileURL: key.subsetFileURL(rootURL: rootURL),
            metadataURL: key.metadataFileURL(rootURL: rootURL)
        )
    }

    private func loadValidRecord(
        key: HrrrPressureSubsetGribCacheKey,
        fileURL: URL,
        metadataURL: URL,
        now: Date
    ) -> HrrrPressureSubsetGribCacheRecord? {
        guard fileManager.fileExists(atPath: fileURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let metadataData = try Data(contentsOf: metadataURL)
            let record = try jsonDecoder.decode(HrrrPressureSubsetGribCacheRecord.self, from: metadataData)

            guard record.expiresAt > now else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard record.key == key else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard record.byteSize <= maximumByteCount else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            let data = try Data(contentsOf: fileURL)
            guard !data.isEmpty else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard data.count == Int(record.byteSize) else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            let checksum = Self.sha256Hex(of: data)
            guard checksum == record.checksumSHA256 else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            return record
        } catch {
            invalidate(fileURL: fileURL, metadataURL: metadataURL)
            return nil
        }
    }

    private func write(record: HrrrPressureSubsetGribCacheRecord, to metadataURL: URL) throws {
        do {
            let data = try jsonEncoder.encode(record)
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            throw HrrrPressureSubsetGribCacheError.unableToWriteCache(path: metadataURL, reason: String(describing: error))
        }
    }

    private func invalidate(fileURL: URL, metadataURL: URL) {
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
