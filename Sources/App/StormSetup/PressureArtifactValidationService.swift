import Foundation

struct PressureArtifactValidationResult: Sendable, Equatable {
    let stdoutLineCount: Int

    init(stdoutLineCount: Int) {
        self.stdoutLineCount = stdoutLineCount
    }
}

protocol PressureArtifactValidating: Sendable {
    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult
}

enum PressureArtifactValidationError: Error, Sendable, CustomStringConvertible {
    case executableMissing(URL)
    case executableNotExecutable(URL)
    case emptyOutput(URL)
    case processRunnerFailure(String)

    var description: String {
        switch self {
        case .executableMissing(let url):
            return "Configured wgrib2 executable does not exist at \(url.path)."
        case .executableNotExecutable(let url):
            return "Configured wgrib2 executable is not executable at \(url.path)."
        case .emptyOutput(let url):
            return "wgrib2 validation produced no output for \(url.path)."
        case .processRunnerFailure(let reason):
            return "wgrib2 validation failed: \(reason)"
        }
    }
}

struct DefaultPressureArtifactValidationService: PressureArtifactValidating {
    private let configuration: StormSetupConfiguration
    private let runner: ProcessRunner

    init(configuration: StormSetupConfiguration, runner: ProcessRunner) {
        self.configuration = configuration
        self.runner = runner
    }

    func validate(localFileURL: URL) async throws -> PressureArtifactValidationResult {
        try validateExecutable()

        do {
            let result = try await runner.run(
                executableURL: configuration.wgrib2ExecutableURL,
                arguments: [localFileURL.path, "-s"],
                timeoutSeconds: configuration.wgrib2TimeoutSeconds
            )

            let lineCount = result.stdout
                .split(whereSeparator: \.isNewline)
                .filter { $0.isEmpty == false }
                .count

            guard lineCount > 0 else {
                throw PressureArtifactValidationError.emptyOutput(localFileURL)
            }

            return PressureArtifactValidationResult(stdoutLineCount: lineCount)
        } catch let error as ProcessRunnerError {
            throw PressureArtifactValidationError.processRunnerFailure(String(reflecting: error))
        }
    }

    private func validateExecutable() throws {
        let executablePath = configuration.wgrib2ExecutableURL.path
        let fileManager = FileManager.default

        guard fileManager.fileExists(atPath: executablePath) else {
            throw PressureArtifactValidationError.executableMissing(configuration.wgrib2ExecutableURL)
        }

        guard fileManager.isExecutableFile(atPath: executablePath) else {
            throw PressureArtifactValidationError.executableNotExecutable(configuration.wgrib2ExecutableURL)
        }
    }
}
