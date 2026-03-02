import Queues
import Vapor

// Api Routes
func configureAPIRoutes(_ app: Application) throws {

    // MARK: Health APIs
    app.group("health") { health in
        health.get() { _ in
            "ok"
        }
        // TODO: DB endpoint health?
    }
    
    // MARK: V1 Device APIs
    app.group("api", "v1", "devices") { devices in
        devices.get() { req async throws in
            "fetch the devices"
        }
        
        devices.post("location-snapshots") { req async throws -> LocationSnapshotAcceptedResponse in
            let payload = try req.content.decode(LocationSnapshotPushPayload.self)

//            guard (-90.0...90.0).contains(payload.latitude),
//                  (-180.0...180.0).contains(payload.longitude) else {
//                throw Abort(.badRequest, reason: "Invalid coordinates")
//            }

            guard !payload.apnsDeviceToken.isEmpty else {
                throw Abort(.badRequest, reason: "Missing apnsDeviceToken")
            }

            // TODO: persist or enqueue for downstream processing.
            // Avoid logging full APNS token in production logs.
//            req.logger.info("location snapshot ts=\(payload.timestamp.ISO8601Format()) lat=\(payload.latitude) lon=\(payload.longitude) h3=\(payload.h3Cell ?? "nil") county=\(payload.county ?? "nil") zone=\(payload.zone ?? "nil") fireZone=\(payload.fireZone ?? "nil")")
            req.logger.info("location snapshot ts=\(payload.timestamp.ISO8601Format()) h3=\(payload.h3Cell ?? "nil") county=\(payload.county ?? "nil") zone=\(payload.zone ?? "nil") fireZone=\(payload.fireZone ?? "nil")")
            return .init(status: "ok", receivedAt: Date())
        }
        
//        devices.group(":id") { device in
//            app.get("hello", ":name") { req -> String in
        //        let name = req.parameters.get("name")!
        //        return "Hello, \(name)!"
        //    }
//        }
    }

    app.group("api", "v1", "dev") { dev in
        dev.post("replay-ingest") { req async throws -> Response in
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
}
