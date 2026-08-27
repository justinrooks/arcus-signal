//
//  AnvilProfilePreviewController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 6/19/26.
//

import Foundation
import Vapor

struct AnvilProfilePreviewController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "dev", "anvil").get("profile-preview", use: profilePreview)
        }
    }

    func profilePreview(req: Request) async throws -> AnvilAnalyzeProfilePreviewResponse {
        guard req.application.arcusDebugEndpointsEnabled,
              req.application.environment != .production else {
            throw Abort(.notFound)
        }

        let query = try req.query.decode(ProfilePreviewQuery.self)
        let h3Cell = try normalizedH3Cell(from: query.h3)

        do {
            return try await req.application.anvilProfilePreviewProvider.previewProfile(for: h3Cell)
        } catch let error as AnvilProfilePreviewError {
            throw error.asAbort()
        }
    }
}

private extension AnvilProfilePreviewController {
    struct ProfilePreviewQuery: Content {
        let h3: String?
    }

    func normalizedH3Cell(from rawValue: String?) throws -> Int64 {
        guard let rawValue,
              let trimmed = normalizedOptional(rawValue) else {
            throw Abort(.badRequest, reason: "Missing required query parameter 'h3'.")
        }

        guard let h3Cell = Int64(trimmed) else {
            throw Abort(.badRequest, reason: "Invalid H3 cell '\(rawValue)'. Expected a signed 64-bit integer.")
        }
        return h3Cell
    }
}
