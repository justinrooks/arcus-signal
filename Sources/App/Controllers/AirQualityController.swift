import ArcusCore
import Foundation
import Vapor

struct AirQualityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "air-quality").get("current", use: current)
        }
    }

    func current(req: Request) async throws -> AirQualityCurrentResponse {
        let query = try req.query.decode(CurrentQuery.self)
        guard let rawH3 = query.h3?.trimmingCharacters(in: .whitespacesAndNewlines),
              let h3Cell = Int64(rawH3) else {
            throw Abort(.badRequest, reason: "Missing or invalid required query parameter 'h3'.")
        }
        guard let response = try await req.application.airQualityProvider.currentResponse(for: h3Cell) else {
            throw Abort(.serviceUnavailable, reason: "Current AQI is unavailable.")
        }
        return response
    }

    private struct CurrentQuery: Content {
        let h3: String?
    }
}
