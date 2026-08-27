import Fluent
import Vapor

struct AnvilProfileAnalysisController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "dev", "anvil").get("profile-analysis", use: analyzeProfile)
        }
    }

    func analyzeProfile(req: Request) async throws -> Response {
        guard req.application.arcusDebugEndpointsEnabled,
              req.application.environment != .production else {
            throw Abort(.notFound)
        }

        guard let h3Cell = req.query[Int64.self, at: "h3"] else {
            throw Abort(.badRequest, reason: "Missing required query parameter 'h3'.")
        }

        do {
            let response = try await req.application.anvilProfileAnalysisProvider.analyzeProfile(for: h3Cell)
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
}
