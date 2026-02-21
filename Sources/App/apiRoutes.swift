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
    app.group("v1","devices") { devices in
        devices.get() { req async throws in
            "fetch the devices"
        }
        
        devices.post("register") { req async throws in
            "register device!"
//            req.content.decode(tbd)
        }
        
        devices.post("checkin") { req async throws in
            "Record latest device cell and prefs"
//            req.content.decode(tbd)
        }
        
//        devices.group(":id") { device in
//            app.get("hello", ":name") { req -> String in
        //        let name = req.parameters.get("name")!
        //        return "Hello, \(name)!"
        //    }
//        }
    }
}
