//
//  Wgrib2Client.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation

protocol Wgrib2Sampling: Sendable {
    func samplePoint(_ request: Wgrib2PointRequest) async throws -> [Wgrib2PointSample]
}

enum Wgrib2ClientError: Error, Sendable, CustomStringConvertible {
    case executableMissing(URL)
    case executableNotExecutable(URL)

    var description: String {
        switch self {
        case .executableMissing(let url):
            return "Configured wgrib2 executable does not exist at \(url.path)."
        case .executableNotExecutable(let url):
            return "Configured wgrib2 executable is not executable at \(url.path)."
        }
    }
}

struct Wgrib2Client: Sendable {
    let configuration: StormSetupConfiguration
    let runner: ProcessRunner
    
    init(
        configuration: StormSetupConfiguration = .default,
        runner: ProcessRunner = ProcessRunner()
    ) {
        self.configuration = configuration
        self.runner = runner
    }

    func samplePoint(_ request: Wgrib2PointRequest) async throws -> [Wgrib2PointSample] {
        try validateExecutable()

        let arguments = makeArguments(for: request)

        let result = try await runner.run(
            executableURL: configuration.wgrib2ExecutableURL,
            arguments: arguments,
            timeoutSeconds: configuration.wgrib2TimeoutSeconds
        )

        return result.stdout
            .split { $0.isNewline }
            .map(String.init)
            .filter { $0.isEmpty == false }
            .map(Wgrib2PointSample.parse(from:))
    }

    private func validateExecutable() throws {
        let executablePath = configuration.wgrib2ExecutableURL.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: executablePath) else {
            throw Wgrib2ClientError.executableMissing(configuration.wgrib2ExecutableURL)
        }

        guard fileManager.isExecutableFile(atPath: executablePath) else {
            throw Wgrib2ClientError.executableNotExecutable(configuration.wgrib2ExecutableURL)
        }
    }

    func makeArguments(for request: Wgrib2PointRequest) -> [String] {
        var arguments: [String] = [request.fileURL.path]

        if let matchPattern = normalizedMatchPattern(request.matchPattern) {
            arguments += ["-match", matchPattern]
        }

        arguments += [
            "-s",
            "-lon",
            String(request.longitude),
            String(request.latitude)
        ]

        return arguments
    }

    private func normalizedMatchPattern(_ pattern: String?) -> String? {
        guard let pattern else {
            return nil
        }

        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Wgrib2Client: Wgrib2Sampling {}
