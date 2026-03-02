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
}
