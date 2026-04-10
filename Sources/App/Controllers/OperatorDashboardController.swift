import Vapor

struct OperatorDashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let metrics = routes.grouped("v1")
        metrics.get("metrics", use: metricsSnapshot)
        routes.get("dashboard", use: dashboard)
    }

    func metricsSnapshot(req: Request) async throws -> OperatorDashboardSnapshotResponse {
        guard let snapshot = try await req.application.operatorDashboardSnapshotStore.load(on: req.db) else {
            throw Abort(.serviceUnavailable, reason: "Operator dashboard snapshot unavailable.")
        }

        return .init(snapshot: snapshot, renderedAt: .now)
    }

    func dashboard(req: Request) async throws -> Response {
        if let snapshot = try await req.application.operatorDashboardSnapshotStore.load(on: req.db) {
            return htmlResponse(
                status: .ok,
                html: OperatorDashboardPageRenderer.render(
                    snapshot: .init(snapshot: snapshot, renderedAt: .now)
                )
            )
        }

        return htmlResponse(
            status: .serviceUnavailable,
            html: OperatorDashboardPageRenderer.renderUnavailable()
        )
    }

    private func htmlResponse(status: HTTPResponseStatus, html: String) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(string: html)
        return response
    }
}
