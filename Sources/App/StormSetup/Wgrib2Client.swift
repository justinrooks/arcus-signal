//
//  Wgrib2Client.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation

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
