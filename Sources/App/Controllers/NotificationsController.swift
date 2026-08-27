//
//  NotificationsController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/28/26.
//

import Fluent
import Vapor

private struct NotificationLookupQuery: Content {
    let status: String?
}

struct NotificationsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "notifications").get(use: index)
        }
    }

    func index(req: Request) async throws -> [NotificationLedgerModel] {
        let query = try req.query.decode(NotificationLookupQuery.self)

        if let status = query.status, status != "all" {
            let allowedStatuses: Set<String> = ["claimed", "sent", "failed"]
            guard allowedStatuses.contains(status) else {
                throw Abort(.badRequest, reason: "unsupported status filter: \(status)")
            }

            return try await NotificationLedgerModel.query(on: req.db)
                .filter(\.$status == status)
                .all()
        }

        return try await NotificationLedgerModel.query(on: req.db).all()
    }
}
