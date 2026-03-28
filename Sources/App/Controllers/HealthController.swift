//
//  HealthController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/28/26.
//

import Fluent
import Vapor

struct HealthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let health = routes.grouped("health")
        health.get(use: index)
    }

    func index(req: Request) async throws -> Response {
        return .init(status: .ok)
//        // MARK: Health APIs
//        app.group("health") { health in
//            health.get() { _ in
//                
//            }
//            // TODO: DB endpoint health?
//        }
//        let query = try req.query.decode(NotificationLookupQuery.self)
//
//        if let status = query.status, status != "all" {
//            let allowedStatuses: Set<String> = ["claimed", "sent", "failed"]
//            guard allowedStatuses.contains(status) else {
//                throw Abort(.badRequest, reason: "unsupported status filter: \(status)")
//            }
//
//            return try await NotificationLedgerModel.query(on: req.db)
//                .filter(\.$status == status)
//                .all()
//        }
//
//        return try await NotificationLedgerModel.query(on: req.db).all()
    }
}
