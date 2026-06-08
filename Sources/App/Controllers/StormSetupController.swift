//
//  StormSetupController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/7/26.
//

import Foundation
import Vapor

struct StormSetupController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let stormSetup = routes.grouped("api", "v1", "storm-setup")
        stormSetup.get("current", use: current)
    }

    func current(req: Request) async throws -> TornadoIngredientSnapshot {
        let query = try req.query.decode(CurrentQuery.self)
        let h3Cell = try normalizedH3Cell(from: query.h3)

        do {
            return try await req.application.stormSetupProvider.currentSnapshot(for: h3Cell)
        } catch let error as StormSetupCurrentSnapshotError {
            throw error.asAbort()
        } catch {
            throw error
        }
    }
}

private extension StormSetupController {
    struct CurrentQuery: Content {
        let h3: String?
    }

    func normalizedH3Cell(from rawValue: String?) throws -> Int64 {
        guard let rawValue,
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Abort(.badRequest, reason: "Missing required query parameter 'h3'.")
        }

        guard let h3Cell = Int64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Abort(.badRequest, reason: "Invalid H3 cell '\(rawValue)'. Expected a signed 64-bit integer.")
        }

        return h3Cell
    }
}
