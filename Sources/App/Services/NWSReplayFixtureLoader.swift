import Foundation
import Logging
import Vapor

public protocol NWSReplayFixtureLoader: Sendable {
    func loadEvents(
        fixtureName: String,
        on application: Application,
        logger: Logger
    ) throws -> [ArcusEvent]
}

public enum NWSReplayFixtureLoaderError: Error, Sendable {
    case invalidFixtureName
    case fixtureNotFound(path: String)
}

public struct LocalNWSReplayFixtureLoader: NWSReplayFixtureLoader {
    private static let fixtureDirectory = "Fixtures/NWSReplay"

    public init() {}

    public func loadEvents(
        fixtureName: String,
        on application: Application,
        logger: Logger
    ) throws -> [ArcusEvent] {
        let fileName = try sanitizedFixtureFileName(from: fixtureName)
        let fixturePath = makeFixturePath(fileName: fileName, application: application)

        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw NWSReplayFixtureLoaderError.fixtureNotFound(path: fixturePath)
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: fixturePath))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(NwsEventDTO.self, from: data)
        let events = decoded.toArcusEvents(now: .now, rawRef: fixturePath)

        logger.info(
            "Loaded replay ingest fixture.",
            metadata: [
                "fixtureName": .string(fileName),
                "fixturePath": .string(fixturePath),
                "nwsFeatures": .stringConvertible(decoded.features?.count ?? 0),
                "arcusEvents": .stringConvertible(events.count)
            ]
        )

        return events
    }

    private func sanitizedFixtureFileName(from rawValue: String) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withExtension = trimmed.hasSuffix(".json") ? trimmed : "\(trimmed).json"
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

        guard !withExtension.isEmpty,
              withExtension.unicodeScalars.allSatisfy(allowed.contains),
              withExtension.contains("..") == false,
              withExtension.contains("/") == false,
              withExtension.contains("\\") == false else {
            throw NWSReplayFixtureLoaderError.invalidFixtureName
        }

        return withExtension
    }

    private func makeFixturePath(fileName: String, application: Application) -> String {
        let root = URL(fileURLWithPath: application.directory.workingDirectory, isDirectory: true)
        return root
            .appendingPathComponent(Self.fixtureDirectory, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .path
    }
}

private struct NWSReplayFixtureLoaderKey: StorageKey {
    typealias Value = any NWSReplayFixtureLoader
}

public extension Application {
    var nwsReplayFixtureLoader: any NWSReplayFixtureLoader {
        get {
            storage[NWSReplayFixtureLoaderKey.self] ?? LocalNWSReplayFixtureLoader()
        }
        set {
            storage[NWSReplayFixtureLoaderKey.self] = newValue
        }
    }
}

