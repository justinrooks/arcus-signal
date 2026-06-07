//
//  Wgrib2Client.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation

struct GribPointRequest: Sendable {
    let fileURL: URL
    let longitude: Double
    let latitude: Double
    let matchPattern: String?
}

struct GribPointRecord: Sendable, Codable {
    let inventory: String
    let value: Double?
}

struct Wgrib2Client: Sendable {
    let executableURL: URL
    let runner: ProcessRunner

    func samplePoint(_ request: GribPointRequest) async throws -> [GribPointRecord] {
        var arguments: [String] = [
            request.fileURL.path
        ]

        if let matchPattern = request.matchPattern {
            arguments += ["-match", matchPattern]
        }

        arguments += [
            "-lon",
            String(request.longitude),
            String(request.latitude)
        ]

        let result = try await runner.run(
            executableURL: executableURL,
            arguments: arguments,
            timeoutSeconds: 15
        )

        return result.stdout
            .split(separator: "\n")
            .map(String.init)
            .map(parsePointRecord)
    }

    private func parsePointRecord(_ line: String) -> GribPointRecord {
        // wgrib2 output commonly includes a "val=" token for point samples.
        // Example shape varies by option/version, so keep this parser tolerant.
        let value = line
            .split(separator: " ")
            .first(where: { $0.hasPrefix("val=") })
            .flatMap { token -> Double? in
                let raw = token.replacingOccurrences(of: "val=", with: "")
                return Double(raw)
            }

        return GribPointRecord(
            inventory: line,
            value: value
        )
    }
}
//
//let client = Wgrib2Client(
//    executableURL: URL(fileURLWithPath: "/usr/local/bin/wgrib2"),
//    runner: ProcessRunner()
//)
//
//let records = try await client.samplePoint(
//    GribPointRequest(
//        fileURL: URL(fileURLWithPath: "/tmp/hrrr_subset.grib2"),
//        longitude: -104.4661,
//        latitude: 39.7825,
//        matchPattern: ":CAPE:"
//    )
//)

