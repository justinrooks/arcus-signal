import Fluent
import Vapor

struct AnvilProfileAnalysisController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let dev = routes.grouped("api", "v1", "dev", "anvil")
        dev.get("profile-analysis", use: analyzeProfile)
    }

    func analyzeProfile(req: Request) async throws -> Response {
        guard req.application.arcusDebugEndpointsEnabled,
              req.application.environment != .production else {
            throw Abort(.notFound)
        }

        guard let h3Cell = req.query[Int64.self, at: "h3"] else {
            throw Abort(.badRequest, reason: "Missing required query parameter 'h3'.")
        }
        let surfaceHeightMslM = await req.selectedSurfaceHeightMslM(
            for: h3Cell,
            application: req.application
        )

        do {
            let response = try await req.application.anvilProfileAnalysisProvider.analyzeProfile(
                for: h3Cell,
                surfaceHeightMslM: surfaceHeightMslM
            )
            return try req.contentEncode(response, status: .ok)
        } catch let error as AnvilProfileAnalysisError {
            throw error.asAbort()
        }
    }
}

private extension Request {
    func contentEncode<T: Content>(_ value: T, status: HTTPResponseStatus) throws -> Response {
        let response = Response(status: status)
        try response.content.encode(value)
        return response
    }

    func selectedSurfaceHeightMslM(for h3Cell: Int64, application: Application) async -> Double? {
        do {
            return try await application.stormSetupProvider.currentSnapshot(for: h3Cell).surfaceHeightMslM
        } catch {
            application.logger.warning(
                "Unable to resolve selected surface height for Anvil analysis; continuing without below-ground filtering.",
                metadata: [
                    "h3": .string("\(h3Cell)"),
                    "error": .string(String(describing: error))
                ]
            )
            return nil
        }
    }
}
