import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import ArcusCore

struct GribSubsetCacheResult: Sendable {
    let source: StormSetupSourceMetadata
    let localFileURL: URL
    let byteSize: Int64
    let fetchedAt: Date
    let expiresAt: Date
    let cacheHit: Bool

    var localFilePath: String {
        localFileURL.path
    }
}

struct GribSubsetCacheRecord: Codable, Sendable {
    let source: StormSetupSourceMetadata
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
    let expiresAt: Date
}

enum GribSubsetCacheError: Error, Sendable, CustomStringConvertible {
    case missingNomadsURL(source: StormSetupSourceMetadata)
    case unexpectedHTTPStatus(source: StormSetupSourceMetadata, status: Int)
    case emptyResponseBody(source: StormSetupSourceMetadata)
    case responseTooLarge(source: StormSetupSourceMetadata, byteCount: Int, maximumByteCount: Int)
    case rejectedTextResponse(source: StormSetupSourceMetadata, preview: String)
    case invalidCachedFile(source: StormSetupSourceMetadata, reason: String)
    case checksumMismatch(source: StormSetupSourceMetadata, expected: String, actual: String)
    case unableToWriteCache(path: URL, reason: String)
    case unableToReadCache(path: URL, reason: String)

    var description: String {
        switch self {
        case .missingNomadsURL(let source):
            return "Missing NOMADS URL for source metadata: \(source)."
        case .unexpectedHTTPStatus(let source, let status):
            return "NOMADS returned HTTP \(status) for source metadata: \(source)."
        case .emptyResponseBody(let source):
            return "NOMADS returned an empty body for source metadata: \(source)."
        case .responseTooLarge(let source, let byteCount, let maximumByteCount):
            return "NOMADS response was \(byteCount) bytes, exceeding the cache limit of \(maximumByteCount) bytes for source metadata: \(source)."
        case .rejectedTextResponse(let source, let preview):
            return "NOMADS returned obvious text or HTML for source metadata: \(source). Preview: \(preview)"
        case .invalidCachedFile(let source, let reason):
            return "Cached GRIB subset is invalid for source metadata: \(source). Reason: \(reason)"
        case .checksumMismatch(let source, let expected, let actual):
            return "Cached GRIB subset checksum mismatch for source metadata: \(source). Expected \(expected), got \(actual)."
        case .unableToWriteCache(let path, let reason):
            return "Unable to write GRIB subset cache at \(path.path): \(reason)"
        case .unableToReadCache(let path, let reason):
            return "Unable to read GRIB subset cache at \(path.path): \(reason)"
        }
    }
}

actor GribSubsetCache {
    private let httpClient: any HTTPClient
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let filesystemCriticalSection = BlockingWorkCriticalSection()
    private let rootURL: URL
    private let dateProvider: any StormSetupDateProviding
    private let retentionDuration: TimeInterval
    private let maximumByteCount: Int

    init(
        httpClient: any HTTPClient,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        rootURL: URL = StormSetupConfiguration.localGribSubsetCacheRootURL,
        dateProvider: any StormSetupDateProviding = SystemStormSetupDateProvider(),
        retentionDuration: TimeInterval = StormSetupConfiguration.default.gribSubsetCacheRetentionSeconds,
        maximumByteCount: Int = StormSetupConfiguration.default.gribSubsetMaximumByteCount
    ) {
        self.httpClient = httpClient
        self.blockingWorkExecutor = blockingWorkExecutor
        self.rootURL = rootURL
        self.dateProvider = dateProvider
        self.retentionDuration = retentionDuration
        self.maximumByteCount = maximumByteCount
    }

    func loadOrFetch(sourceMetadata: StormSetupSourceMetadata) async throws -> GribSubsetCacheResult {
        let key = try StormSetupCacheKey(sourceMetadata: sourceMetadata)
        let fileURL = key.subsetFileURL(rootURL: rootURL)
        let metadataURL = key.metadataFileURL(rootURL: rootURL)
        let now = dateProvider.now()

        if let record = try await loadValidRecord(
            key: key,
            fileURL: fileURL,
            metadataURL: metadataURL,
            now: now
        ) {
            return GribSubsetCacheResult(
                source: record.source,
                localFileURL: fileURL,
                byteSize: record.byteSize,
                fetchedAt: record.fetchedAt,
                expiresAt: record.expiresAt,
                cacheHit: true
            )
        }

        let directoryURL = key.directoryURL(rootURL: rootURL)
        try await executeFilesystemWork {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        guard let sourceURL = sourceMetadata.primaryDownloadURL else {
            throw GribSubsetCacheError.missingNomadsURL(source: sourceMetadata)
        }

        try Task.checkCancellation()
        let response = try await httpClient.get(sourceURL, headers: nomadsRequestHeaders)
        try Task.checkCancellation()

        guard (200...299).contains(response.status) else {
            throw GribSubsetCacheError.unexpectedHTTPStatus(source: sourceMetadata, status: response.status)
        }

        guard let body = response.data, !body.isEmpty else {
            throw GribSubsetCacheError.emptyResponseBody(source: sourceMetadata)
        }

        guard body.count <= maximumByteCount else {
            throw GribSubsetCacheError.responseTooLarge(
                source: sourceMetadata,
                byteCount: body.count,
                maximumByteCount: maximumByteCount
            )
        }

        try rejectObviousTextResponses(body: body, response: response, sourceMetadata: sourceMetadata)

        let expiresAt = now.addingTimeInterval(retentionDuration)

        do {
            try await executeFilesystemWork {
                let record = GribSubsetCacheRecord(
                    source: sourceMetadata,
                    byteSize: Int64(body.count),
                    checksumSHA256: Self.sha256Hex(of: body),
                    fetchedAt: now,
                    expiresAt: expiresAt
                )

                do {
                    try body.write(to: fileURL, options: [.atomic])
                    let jsonEncoder = Self.makeJSONEncoder()
                    let metadataData = try jsonEncoder.encode(record)
                    do {
                        try metadataData.write(to: metadataURL, options: [.atomic])
                    } catch {
                        throw GribSubsetCacheError.unableToWriteCache(
                            path: metadataURL,
                            reason: String(describing: error)
                        )
                    }
                } catch {
                    try? FileManager.default.removeItem(at: fileURL)
                    try? FileManager.default.removeItem(at: metadataURL)
                    throw error
                }
            }
        } catch {
            try rethrowCancellationIfNeeded(error)
            throw GribSubsetCacheError.unableToWriteCache(path: fileURL, reason: String(describing: error))
        }

        return GribSubsetCacheResult(
            source: sourceMetadata,
            localFileURL: fileURL,
            byteSize: Int64(body.count),
            fetchedAt: now,
            expiresAt: expiresAt,
            cacheHit: false
        )
    }

    private func loadValidRecord(
        key: StormSetupCacheKey,
        fileURL: URL,
        metadataURL: URL,
        now: Date
    ) async throws -> GribSubsetCacheRecord? {
        return try await executeFilesystemWork {
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  FileManager.default.fileExists(atPath: metadataURL.path) else {
                return nil
            }

            do {
                let metadataData = try Data(contentsOf: metadataURL)
                let jsonDecoder = Self.makeJSONDecoder()
                let record = try jsonDecoder.decode(GribSubsetCacheRecord.self, from: metadataData)

                guard record.expiresAt > now else {
                    Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                    return nil
                }

                let expectedKey = try StormSetupCacheKey(sourceMetadata: record.source)
                guard expectedKey == key else {
                    Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                    return nil
                }

                let data = try Data(contentsOf: fileURL)
                guard !data.isEmpty else {
                    Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                    return nil
                }

                guard data.count == Int(record.byteSize) else {
                    Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                    return nil
                }

                let checksum = Self.sha256Hex(of: data)
                guard checksum == record.checksumSHA256 else {
                    Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                    return nil
                }

                return record
            } catch {
                Self.invalidate(fileURL: fileURL, metadataURL: metadataURL)
                return nil
            }
        }
    }

    private static func invalidate(fileURL: URL, metadataURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: metadataURL)
    }

    private func executeFilesystemWork<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let filesystemCriticalSection = filesystemCriticalSection
        return try await blockingWorkExecutor.execute {
            try filesystemCriticalSection.withLock(operation)
        }
    }

    private func rejectObviousTextResponses(
        body: Data,
        response: HTTPResponse,
        sourceMetadata: StormSetupSourceMetadata
    ) throws {
        let contentType = response.header("Content-Type")?.lowercased()
        if let contentType, contentType.contains("text/html") {
            let preview = bodyPreview(from: body)
            throw GribSubsetCacheError.rejectedTextResponse(source: sourceMetadata, preview: preview)
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
            throw GribSubsetCacheError.rejectedTextResponse(
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

    private var nomadsRequestHeaders: [String: String] {
        [
            "User-Agent": HTTPRequestHeaders.userAgent(),
            "Accept": "application/octet-stream, application/x-grib2, application/grib2, */*"
        ]
    }

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
