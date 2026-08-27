//
//  DevController.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/28/26.
//

import Fluent
import Vapor

struct DevController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "dev").post(use: index)
        }
    }

    func index(req: Request) async throws -> Response {
        guard req.application.environment != .production else {
            throw Abort(.notFound)
        }
        
        let request = try req.content.decode(ReplayIngestRequest.self)
        let fixtureName = request.fixtureName.trimmingCharacters(in: .whitespacesAndNewlines)
        let runLabel = request.runLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !fixtureName.isEmpty else {
            throw Abort(.badRequest, reason: "fixtureName is required")
        }
        
        req.logger.info(
            "Replay ingest accepted.",
            metadata: [
                "fixtureName": .string(fixtureName),
                "runLabel": .string(runLabel ?? "none")
            ]
        )
        
        let payload = IngestNWSAlertsPayload(
            source: .fixture,
            fixtureName: fixtureName,
            runLabel: runLabel
        )
        try await req.application.queues
            .queue(ArcusQueueLane.ingest.queueName)
            .dispatch(IngestNWSAlertsJob.self, payload)
        
        let accepted = ReplayIngestAcceptedResponse(
            status: "accepted",
            source: IngestNWSAlertsSource.fixture.rawValue,
            fixtureName: fixtureName,
            runLabel: runLabel,
            queuedAt: Date()
        )
        let response = Response(status: .accepted)
        try response.content.encode(accepted)
        return response
    }
}
