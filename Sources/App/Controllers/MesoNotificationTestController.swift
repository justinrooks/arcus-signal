import Fluent
import Foundation
import SwiftyH3
import Vapor

struct MesoNotificationTestController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        try registerOnAPIRoots(routes) { root in
            root.grouped("v1", "dev").post("notification-test", use: testNotification)
        }
    }

    func testNotification(req: Request) async throws -> Response {
        guard let configuration = req.application.mesoNotificationTestEndpointConfiguration else {
            throw Abort(.notFound)
        }
        guard isAuthorized(req.headers[.authorization].first, secret: configuration.bearerSecret) else {
            throw Abort(.unauthorized)
        }

        let payload = try req.content.decode(MesoNotificationTestRequest.self)
        guard payload.type == "meso" else {
            throw Abort(.badRequest, reason: "type must be meso")
        }

        let cell = H3Cell(UInt64(bitPattern: payload.h3Cell))
        guard cell.isValid, try cell.resolution == .res8 else {
            throw Abort(.badRequest, reason: "h3Cell must be a valid resolution-8 H3 cell")
        }
        guard try await DeviceInstallationModel.find(payload.installationId, on: req.db) != nil else {
            throw Abort(.notFound, reason: "Unknown installation")
        }

        let product = try await SyntheticMesoService().create(h3Cell: payload.h3Cell, on: req.db)
        let response = Response(status: .created)
        try response.content.encode(MesoNotificationTestResponse(
            status: "fixture-created", productID: product.productID, validEnd: product.validEnd
        ))
        return response
    }
}

private struct MesoNotificationTestRequest: Content {
    let installationId: UUID
    let h3Cell: Int64
    let type: String
}

private struct MesoNotificationTestResponse: Content {
    let status: String
    let productID: String
    let validEnd: Date
}

private func isAuthorized(_ authorization: String?, secret: String) -> Bool {
    guard let authorization, authorization.hasPrefix("Bearer ") else { return false }
    let supplied = Array(authorization.dropFirst("Bearer ".count).utf8)
    let expected = Array(secret.utf8)
    guard supplied.count == expected.count else { return false }
    return zip(supplied, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
