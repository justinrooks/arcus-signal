import ArcusCore
import Foundation
import Vapor

protocol AirQualityCurrentProviding: Sendable {
    func currentResponse(for h3Cell: Int64) async throws -> AirQualityCurrentResponse?
}

struct UnavailableAirQualityProvider: AirQualityCurrentProviding {
    func currentResponse(for h3Cell: Int64) async throws -> AirQualityCurrentResponse? {
        nil
    }
}

actor AirQualityCurrentCache {
    private struct Entry: Sendable {
        let response: AirQualityCurrentResponse?
        let expiresAt: Date
    }

    private var entries: [Int64: Entry] = [:]

    func response(for h3Cell: Int64, now: Date) -> AirQualityCurrentResponse?? {
        guard let entry = entries[h3Cell], entry.expiresAt > now else { return nil }
        return entry.response
    }

    func store(_ response: AirQualityCurrentResponse?, for h3Cell: Int64, expiresAt: Date) {
        entries[h3Cell] = Entry(response: response, expiresAt: expiresAt)
    }
}

struct DefaultAirQualityProvider: AirQualityCurrentProviding {
    private let configuration: AirQualityConfiguration
    private let client: any AirNowClient
    private let h3Resolver: any StormSetupH3Resolving
    private let cache: AirQualityCurrentCache
    private let now: @Sendable () -> Date

    init(
        configuration: AirQualityConfiguration,
        client: any AirNowClient,
        h3Resolver: any StormSetupH3Resolving = DefaultStormSetupH3Resolver(),
        cache: AirQualityCurrentCache = AirQualityCurrentCache(),
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.configuration = configuration
        self.client = client
        self.h3Resolver = h3Resolver
        self.cache = cache
        self.now = now
    }

    func currentResponse(for h3Cell: Int64) async throws -> AirQualityCurrentResponse? {
        let requestDate = now()
        if let cached = await cache.response(for: h3Cell, now: requestDate) {
            return cached
        }

        let centroid = try h3Resolver.resolve(h3Cell: h3Cell).centroid
        do {
            let observations = try await client.fetchCurrentObservations(
                latitude: centroid.latitude,
                longitude: centroid.longitude
            )
            let response = AirNowNormalizer.normalize(observations: observations)
            await cache.store(response, for: h3Cell, expiresAt: requestDate.addingTimeInterval(configuration.cacheLifetime))
            return response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }
}

enum AirNowNormalizer {
    static func normalize(observations: [AirNowObservation]) -> AirQualityCurrentResponse? {
        observations
            .compactMap { observation -> AirQualityCurrentResponse? in
                guard let aqi = observation.aqi, aqi >= 0,
                      let observedAt = observation.observedAt else { return nil }
                return AirQualityCurrentResponse(
                    aqi: aqi,
                    category: observation.category.map {
                        AirQualityCategory(identifier: $0.number, name: $0.name)
                    },
                    primaryPollutant: observation.parameterName?.trimmingCharacters(in: .whitespacesAndNewlines),
                    observedAt: observedAt,
                    sourceIdentifier: "airnow"
                )
            }
            .max { lhs, rhs in lhs.aqi < rhs.aqi }
    }
}

private extension AirNowObservation {
    var observedAt: Date? {
        guard (0...23).contains(hourObserved) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd H"
        formatter.timeZone = localTimeZone.flatMap(TimeZone.init(identifier:)) ?? .gmt
        return formatter.date(from: "\(dateObserved) \(hourObserved)")
    }
}
