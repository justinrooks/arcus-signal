import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

struct StormSetupPressureGribCacheResult: Sendable {
    let source: StormSetupSourceMetadata
    let localFileURL: URL
    let downloadURL: URL
    let idxURL: URL?
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
    let expiresAt: Date
    let cacheHit: Bool

    var localFilePath: String {
        localFileURL.path
    }
}

struct StormSetupPressureGribCacheRecord: Codable, Sendable {
    let key: StormSetupPressureGribCacheKey
    let source: StormSetupSourceMetadata
    let downloadURL: URL
    let idxURL: URL?
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
    let expiresAt: Date
}

enum StormSetupPressureGribCacheError: Error, Sendable, CustomStringConvertible {
    case missingDirectObjectURL(source: StormSetupSourceMetadata)
    case unexpectedHTTPStatus(source: StormSetupSourceMetadata, status: Int)
    case emptyResponseBody(source: StormSetupSourceMetadata)
    case responseTooLarge(source: StormSetupSourceMetadata, byteCount: Int, maximumByteCount: Int)
    case rejectedTextResponse(source: StormSetupSourceMetadata, preview: String)
    case invalidCachedFile(source: StormSetupSourceMetadata, reason: String)
    case checksumMismatch(source: StormSetupSourceMetadata, expected: String, actual: String)
    case unableToCreateDirectory(path: URL, reason: String)
    case unableToWriteCache(path: URL, reason: String)

    var description: String {
        switch self {
        case .missingDirectObjectURL(let source):
            return "Missing direct-object GRIB URL for source metadata: \(source)."
        case .unexpectedHTTPStatus(let source, let status):
            return "Direct-object download returned HTTP \(status) for source metadata: \(source)."
        case .emptyResponseBody(let source):
            return "Direct-object download returned an empty body for source metadata: \(source)."
        case .responseTooLarge(let source, let byteCount, let maximumByteCount):
            return "Direct-object download was \(byteCount) bytes, exceeding the cache limit of \(maximumByteCount) bytes for source metadata: \(source)."
        case .rejectedTextResponse(let source, let preview):
            return "Direct-object download looked like text or HTML for source metadata: \(source). Preview: \(preview)"
        case .invalidCachedFile(let source, let reason):
            return "Cached direct-object GRIB file is invalid for source metadata: \(source). Reason: \(reason)"
        case .checksumMismatch(let source, let expected, let actual):
            return "Cached direct-object GRIB checksum mismatch for source metadata: \(source). Expected \(expected), got \(actual)."
        case .unableToCreateDirectory(let path, let reason):
            return "Unable to create direct-object GRIB cache directory at \(path.path): \(reason)"
        case .unableToWriteCache(let path, let reason):
            return "Unable to write direct-object GRIB cache at \(path.path): \(reason)"
        }
    }
}

enum StormSetupPressureGribCacheKeyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingRequiredSourceMetadata(String)
    case unsupportedSourceKind(HrrrSourceKind)

    var description: String {
        switch self {
        case .missingRequiredSourceMetadata(let field):
            return "Storm Setup pressure GRIB cache key is missing required source metadata: \(field)."
        case .unsupportedSourceKind(let sourceKind):
            return "Storm Setup pressure GRIB cache key only supports direct-object sources, not \(sourceKind.rawValue)."
        }
    }
}

struct StormSetupPressureGribCacheKey: Sendable, Hashable, Codable, Equatable {
    let sourceKind: HrrrSourceKind
    let model: HrrrModel
    let product: HrrrProduct
    let domain: HrrrDomain
    let runTime: Date
    let forecastHour: Int
    let validTime: Date
    let fieldSetVersion: HrrrFieldSetVersion

    init(sourceMetadata: StormSetupSourceMetadata) throws {
        guard sourceMetadata.sourceKind == .directObject else {
            throw StormSetupPressureGribCacheKeyError.unsupportedSourceKind(sourceMetadata.sourceKind)
        }
        guard let model = sourceMetadata.model else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("model")
        }
        guard let product = sourceMetadata.product else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("product")
        }
        guard let domain = sourceMetadata.domain else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("domain")
        }
        guard let runTime = sourceMetadata.runTime else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("runTime")
        }
        guard let forecastHour = sourceMetadata.forecastHour else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("forecastHour")
        }
        guard let validTime = sourceMetadata.validTime else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("validTime")
        }
        guard let fieldSetVersion = sourceMetadata.fieldSetVersion else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("fieldSetVersion")
        }
        guard sourceMetadata.primaryDownloadURL != nil else {
            throw StormSetupPressureGribCacheKeyError.missingRequiredSourceMetadata("primaryDownloadURL")
        }

        self.init(
            sourceKind: sourceMetadata.sourceKind,
            model: model,
            product: product,
            domain: domain,
            runTime: runTime,
            forecastHour: forecastHour,
            validTime: validTime,
            fieldSetVersion: fieldSetVersion
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
        fieldSetVersion: HrrrFieldSetVersion
    ) {
        self.sourceKind = sourceKind
        self.model = model
        self.product = product
        self.domain = domain
        self.runTime = runTime
        self.forecastHour = forecastHour
        self.validTime = validTime
        self.fieldSetVersion = fieldSetVersion
    }

    var cacheIdentifier: String {
        pathComponents.joined(separator: "/")
    }

    var pathComponents: [String] {
        [
            "source=direct-object",
            "model=\(model.rawValue.lowercased())",
            "product=\(product.rawValue.lowercased())",
            "domain=\(domain.rawValue.lowercased())",
            "run=\(Self.timestampString(for: runTime))",
            "fh=\(Self.zeroPadded(forecastHour, width: 3))",
            "valid=\(Self.timestampString(for: validTime))",
            "fields=\(fieldSetVersion.rawValue)"
        ]
    }

    func directoryURL(rootURL: URL) -> URL {
        pathComponents.reduce(rootURL) { partialResult, component in
            partialResult.appendingPathComponent(component, isDirectory: true)
        }
    }

    func rawFileURL(rootURL: URL) -> URL {
        directoryURL(rootURL: rootURL).appendingPathComponent("raw.grib2", isDirectory: false)
    }

    func metadataFileURL(rootURL: URL) -> URL {
        directoryURL(rootURL: rootURL).appendingPathComponent("raw.json", isDirectory: false)
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
}

actor StormSetupPressureGribCache {
    private let httpClient: any HTTPClient
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
        rootURL: URL = StormSetupConfiguration.localPressureGribRawCacheRootURL,
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        retentionDuration: TimeInterval = StormSetupConfiguration.default.gribSubsetCacheRetentionSeconds,
        maximumByteCount: Int = StormSetupConfiguration.default.pressureGribRawMaximumByteCount
    ) {
        self.httpClient = httpClient
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

    func loadOrFetch(sourceMetadata: StormSetupSourceMetadata) async throws -> StormSetupPressureGribCacheResult {
        let key = try StormSetupPressureGribCacheKey(sourceMetadata: sourceMetadata)
        let fileURL = key.rawFileURL(rootURL: rootURL)
        let metadataURL = key.metadataFileURL(rootURL: rootURL)
        let now = dateProvider.now()

        if let record = loadValidRecord(key: key, fileURL: fileURL, metadataURL: metadataURL, now: now) {
            return StormSetupPressureGribCacheResult(
                source: record.source,
                localFileURL: fileURL,
                downloadURL: record.downloadURL,
                idxURL: record.idxURL,
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
            throw StormSetupPressureGribCacheError.unableToCreateDirectory(
                path: key.directoryURL(rootURL: rootURL),
                reason: String(describing: error)
            )
        }

        guard let sourceURL = sourceMetadata.primaryDownloadURL else {
            throw StormSetupPressureGribCacheError.missingDirectObjectURL(source: sourceMetadata)
        }

        let response = try await httpClient.get(sourceURL, headers: requestHeaders)

        guard (200...299).contains(response.status) else {
            throw StormSetupPressureGribCacheError.unexpectedHTTPStatus(source: sourceMetadata, status: response.status)
        }

        guard let body = response.data, !body.isEmpty else {
            throw StormSetupPressureGribCacheError.emptyResponseBody(source: sourceMetadata)
        }

        guard body.count <= maximumByteCount else {
            throw StormSetupPressureGribCacheError.responseTooLarge(
                source: sourceMetadata,
                byteCount: body.count,
                maximumByteCount: maximumByteCount
            )
        }

        try rejectObviousTextResponses(body: body, response: response, sourceMetadata: sourceMetadata)

        let checksum = Self.sha256Hex(of: body)
        let expiresAt = now.addingTimeInterval(retentionDuration)
        let record = StormSetupPressureGribCacheRecord(
            key: key,
            source: sourceMetadata,
            downloadURL: sourceURL,
            idxURL: sourceMetadata.idxURL,
            byteSize: Int64(body.count),
            checksumSHA256: checksum,
            fetchedAt: now,
            expiresAt: expiresAt
        )

        do {
            try body.write(to: fileURL, options: [.atomic])
            try write(record: record, to: metadataURL)
        } catch {
            try? fileManager.removeItem(at: fileURL)
            try? fileManager.removeItem(at: metadataURL)
            throw StormSetupPressureGribCacheError.unableToWriteCache(path: fileURL, reason: String(describing: error))
        }

        return StormSetupPressureGribCacheResult(
            source: sourceMetadata,
            localFileURL: fileURL,
            downloadURL: sourceURL,
            idxURL: sourceMetadata.idxURL,
            byteSize: Int64(body.count),
            checksumSHA256: checksum,
            fetchedAt: now,
            expiresAt: expiresAt,
            cacheHit: false
        )
    }

    private func loadValidRecord(
        key: StormSetupPressureGribCacheKey,
        fileURL: URL,
        metadataURL: URL,
        now: Date
    ) -> StormSetupPressureGribCacheRecord? {
        guard fileManager.fileExists(atPath: fileURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            return nil
        }

        do {
            let metadataData = try Data(contentsOf: metadataURL)
            let record = try jsonDecoder.decode(StormSetupPressureGribCacheRecord.self, from: metadataData)

            guard record.expiresAt > now else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard record.key == key else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard let derivedKey = try? StormSetupPressureGribCacheKey(sourceMetadata: record.source),
                  derivedKey == key else {
                invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }

            guard record.downloadURL == record.source.primaryDownloadURL,
                  record.idxURL == record.source.idxURL else {
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

    private func write(record: StormSetupPressureGribCacheRecord, to metadataURL: URL) throws {
        let data = try jsonEncoder.encode(record)
        do {
            try data.write(to: metadataURL, options: [.atomic])
        } catch {
            throw StormSetupPressureGribCacheError.unableToWriteCache(path: metadataURL, reason: String(describing: error))
        }
    }

    private func invalidate(fileURL: URL, metadataURL: URL) {
        try? fileManager.removeItem(at: fileURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    private func rejectObviousTextResponses(
        body: Data,
        response: HTTPResponse,
        sourceMetadata: StormSetupSourceMetadata
    ) throws {
        let contentType = response.header("Content-Type")?.lowercased()
        if let contentType, contentType.contains("text/html") {
            let preview = bodyPreview(from: body)
            throw StormSetupPressureGribCacheError.rejectedTextResponse(source: sourceMetadata, preview: preview)
        }

        guard let text = String(data: body.prefix(1024), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return
        }

        let lowercased = text.lowercased()
        let suspiciousTokens = [
            "<!doctype",
            "<html",
            "<head>",
            "</html>",
            "access denied",
            "bad request",
            "forbidden",
            "not found",
            "error",
            "service unavailable"
        ]

        if suspiciousTokens.contains(where: { lowercased.contains($0) }) {
            throw StormSetupPressureGribCacheError.rejectedTextResponse(
                source: sourceMetadata,
                preview: String(lowercased.prefix(200))
            )
        }
    }

    private func bodyPreview(from body: Data) -> String {
        guard let text = String(data: body.prefix(200), encoding: .utf8) else {
            return "<binary>"
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requestHeaders: [String: String] {
        [
            "User-Agent": HTTPRequestHeaders.userAgent(),
            "Accept": "application/octet-stream, application/x-grib2, application/grib2, */*"
        ]
    }

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
