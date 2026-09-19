import Vapor

struct OperatorDashboardController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let metrics = routes.grouped("v1")
        metrics.get("metrics", use: metricsSnapshot)
        routes.get("dashboard", use: dashboard)
        for page in OperatorDashboardPageRenderer.Page.allCases where page != .overview {
            routes.get("dashboard", PathComponent(stringLiteral: page.rawValue)) { req async throws -> Response in
                try await dashboard(req: req, page: page)
            }
        }
    }

    func metricsSnapshot(req: Request) async throws -> OperatorDashboardSnapshotResponse {
        guard let snapshot = try await req.application.operatorDashboardSnapshotStore.load(on: req.db) else {
            throw Abort(.serviceUnavailable, reason: "Operator dashboard snapshot unavailable.")
        }

        return .init(snapshot: snapshot, renderedAt: .now)
    }

    func dashboard(req: Request) async throws -> Response {
        try await dashboard(req: req, page: .overview)
    }

    private func dashboard(req: Request, page: OperatorDashboardPageRenderer.Page) async throws -> Response {
        if let snapshot = try await req.application.operatorDashboardSnapshotStore.load(on: req.db) {
            return htmlResponse(
                status: .ok,
                html: OperatorDashboardPageRenderer.render(
                    snapshot: .init(snapshot: snapshot, renderedAt: .now),
                    page: page,
                    environment: req.application.environment.name,
                    buildInfo: req.application.arcusSignalBuildInfo
                )
            )
        }

        return htmlResponse(
            status: .serviceUnavailable,
            html: OperatorDashboardPageRenderer.renderUnavailable(
                page: page,
                environment: req.application.environment.name,
                buildInfo: req.application.arcusSignalBuildInfo
            )
        )
    }

    private func htmlResponse(status: HTTPResponseStatus, html: String) -> Response {
        let response = Response(status: status)
        response.headers.contentType = .html
        response.body = .init(string: html)
        return response
    }
}
