import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif
import ArcusCore

struct HrrrPressureByteRangeDownloadResult: Sendable {
    let source: StormSetupSourceMetadata
    let data: Data
    let byteSize: Int64
    let checksumSHA256: String
    let fetchedAt: Date
}

enum HrrrPressureByteRangeDownloaderError: Error, Sendable, CustomStringConvertible {
    case missingDirectObjectURL(source: StormSetupSourceMetadata)
    case rangeNotSatisfiable(source: StormSetupSourceMetadata)
    case serverIgnoredRange(source: StormSetupSourceMetadata, status: Int)
    case unexpectedHTTPStatus(source: StormSetupSourceMetadata, status: Int)
    case emptyResponseBody(source: StormSetupSourceMetadata, range: String)
    case missingContentRange(source: StormSetupSourceMetadata, range: String)
    case rejectedTextResponse(source: StormSetupSourceMetadata, range: String, preview: String)
    case malformedContentRange(source: StormSetupSourceMetadata, range: String, contentRange: String)
    case mismatchedContentRange(source: StormSetupSourceMetadata, range: String, expected: String, actual: String)

    var description: String {
        switch self {
        case .missingDirectObjectURL(let source):
            return "Missing direct-object HRRR pressure URL for source metadata: \(source)."
        case .rangeNotSatisfiable(let source):
            return "HRRR pressure range request returned HTTP 416 for source metadata: \(source)."
        case .serverIgnoredRange(let source, let status):
            return "HRRR pressure range request ignored the Range header and returned HTTP \(status) for source metadata: \(source)."
        case .unexpectedHTTPStatus(let source, let status):
            return "HRRR pressure range request returned HTTP \(status) for source metadata: \(source)."
        case .emptyResponseBody(let source, let range):
            return "HRRR pressure range request returned an empty body for source metadata: \(source). Range: \(range)"
        case .missingContentRange(let source, let range):
            return "HRRR pressure range request was missing Content-Range for source metadata: \(source). Range: \(range)"
        case .rejectedTextResponse(let source, let range, let preview):
            return "HRRR pressure range request returned text or HTML for source metadata: \(source). Range: \(range). Preview: \(preview)"
        case .malformedContentRange(let source, let range, let contentRange):
            return "HRRR pressure range request returned a malformed Content-Range for source metadata: \(source). Range: \(range). Content-Range: \(contentRange)"
        case .mismatchedContentRange(let source, let range, let expected, let actual):
            return "HRRR pressure range request returned a mismatched Content-Range for source metadata: \(source). Range: \(range). Expected \(expected), got \(actual)."
        }
    }
}

struct HrrrPressureByteRangeDownloader: Sendable {
    private let httpClient: any HTTPClient
    private let blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting
    private let requestTimeoutSeconds: TimeInterval

    init(
        httpClient: any HTTPClient,
        blockingWorkExecutor: any PressureArtifactBlockingWorkExecuting,
        requestTimeoutSeconds: TimeInterval = StormSetupConfiguration.default.pressureArtifactHTTPTimeoutSeconds
    ) {
        self.httpClient = httpClient
        self.blockingWorkExecutor = blockingWorkExecutor
        self.requestTimeoutSeconds = requestTimeoutSeconds
    }

    func download(
        sourceMetadata: StormSetupSourceMetadata,
        byteRangePlan: HrrrGribByteRangePlan
    ) async throws -> HrrrPressureByteRangeDownloadResult {
        guard let sourceURL = sourceMetadata.primaryDownloadURL else {
            throw HrrrPressureByteRangeDownloaderError.missingDirectObjectURL(source: sourceMetadata)
        }

        var assembled = Data()
        assembled.reserveCapacity(byteRangePlan.ranges.reduce(0) { partialResult, range in
            guard let closedRange = range.closedRange else {
                return partialResult
            }

            return partialResult + Int(closedRange.upperBound - closedRange.lowerBound + 1)
        })

        for range in byteRangePlan.ranges {
            try Task.checkCancellation()
            let response = try await httpClient.get(
                sourceURL,
                headers: requestHeaders(for: range),
                timeoutSeconds: requestTimeoutSeconds
            )
            try Task.checkCancellation()

            switch response.status {
            case 206:
                break
            case 416:
                throw HrrrPressureByteRangeDownloaderError.rangeNotSatisfiable(source: sourceMetadata)
            case 200:
                throw HrrrPressureByteRangeDownloaderError.serverIgnoredRange(source: sourceMetadata, status: response.status)
            default:
                throw HrrrPressureByteRangeDownloaderError.unexpectedHTTPStatus(source: sourceMetadata, status: response.status)
            }

            guard let body = response.data, !body.isEmpty else {
                throw HrrrPressureByteRangeDownloaderError.emptyResponseBody(
                    source: sourceMetadata,
                    range: range.httpRangeHeaderValue
                )
            }

            try rejectObviousTextResponses(
                body: body,
                response: response,
                sourceMetadata: sourceMetadata,
                range: range.httpRangeHeaderValue
            )

            guard let contentRange = response.header("Content-Range") else {
                throw HrrrPressureByteRangeDownloaderError.missingContentRange(
                    source: sourceMetadata,
                    range: range.httpRangeHeaderValue
                )
            }

            let parsed = try parseContentRange(
                contentRange,
                sourceMetadata: sourceMetadata,
                range: range.httpRangeHeaderValue
            )

            try validate(
                parsedContentRange: parsed,
                requestedRange: range,
                bodyCount: body.count,
                sourceMetadata: sourceMetadata
            )

            assembled.append(body)
        }

        let fetchedAt = Date()
        let checksumInput = assembled
        let checksum = try await blockingWorkExecutor.execute {
            Self.sha256Hex(of: checksumInput)
        }
        try Task.checkCancellation()

        return HrrrPressureByteRangeDownloadResult(
            source: sourceMetadata,
            data: assembled,
            byteSize: Int64(assembled.count),
            checksumSHA256: checksum,
            fetchedAt: fetchedAt
        )
    }

    private func requestHeaders(for range: HrrrGribByteRange) -> [String: String] {
        [
            "User-Agent": HTTPRequestHeaders.userAgent(),
            "Accept": "application/octet-stream, application/x-grib2, application/grib2, */*",
            "Range": range.httpRangeHeaderValue
        ]
    }

    private func validate(
        parsedContentRange: ParsedContentRange,
        requestedRange: HrrrGribByteRange,
        bodyCount: Int,
        sourceMetadata: StormSetupSourceMetadata
    ) throws {
        let expectedStart = requestedRange.startOffset
        guard parsedContentRange.start == expectedStart else {
            throw HrrrPressureByteRangeDownloaderError.mismatchedContentRange(
                source: sourceMetadata,
                range: requestedRange.httpRangeHeaderValue,
                expected: requestedRange.httpRangeHeaderValue,
                actual: parsedContentRange.rawValue
            )
        }

        if let requestedEnd = requestedRange.endOffset {
            guard parsedContentRange.end == requestedEnd else {
                throw HrrrPressureByteRangeDownloaderError.mismatchedContentRange(
                    source: sourceMetadata,
                    range: requestedRange.httpRangeHeaderValue,
                    expected: requestedRange.httpRangeHeaderValue,
                    actual: parsedContentRange.rawValue
                )
            }

            guard Int64(bodyCount) == parsedContentRange.end - parsedContentRange.start + 1 else {
                throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                    source: sourceMetadata,
                    range: requestedRange.httpRangeHeaderValue,
                    contentRange: parsedContentRange.rawValue
                )
            }
            return
        }

        guard parsedContentRange.end >= parsedContentRange.start else {
            throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                source: sourceMetadata,
                range: requestedRange.httpRangeHeaderValue,
                contentRange: parsedContentRange.rawValue
            )
        }

        guard Int64(bodyCount) == parsedContentRange.end - parsedContentRange.start + 1 else {
            throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                source: sourceMetadata,
                range: requestedRange.httpRangeHeaderValue,
                contentRange: parsedContentRange.rawValue
            )
        }
    }

    private func parseContentRange(
        _ value: String,
        sourceMetadata: StormSetupSourceMetadata,
        range: String
    ) throws -> ParsedContentRange {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                source: sourceMetadata,
                range: range,
                contentRange: value
            )
        }

        let body = trimmed.dropFirst("bytes ".count)
        let parts = body.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                source: sourceMetadata,
                range: range,
                contentRange: value
            )
        }

        let intervalParts = parts[0].split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard intervalParts.count == 2,
              let start = Int64(intervalParts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let end = Int64(intervalParts[1].trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HrrrPressureByteRangeDownloaderError.malformedContentRange(
                source: sourceMetadata,
                range: range,
                contentRange: value
            )
        }

        return ParsedContentRange(start: start, end: end, rawValue: value)
    }

    private func rejectObviousTextResponses(
        body: Data,
        response: HTTPResponse,
        sourceMetadata: StormSetupSourceMetadata,
        range: String
    ) throws {
        let contentType = response.header("Content-Type")?.lowercased()
        if let contentType, contentType.contains("text/html") {
            throw HrrrPressureByteRangeDownloaderError.rejectedTextResponse(
                source: sourceMetadata,
                range: range,
                preview: bodyPreview(from: body)
            )
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
            throw HrrrPressureByteRangeDownloaderError.rejectedTextResponse(
                source: sourceMetadata,
                range: range,
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

    private static func sha256Hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private struct ParsedContentRange: Sendable {
    let start: Int64
    let end: Int64
    let rawValue: String
}
