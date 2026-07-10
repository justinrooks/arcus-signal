import Foundation
import SwiftyH3
import Vapor
import ArcusCore

protocol StormSetupH3Resolving: Sendable {
    func resolve(h3Cell: Int64) throws -> StormSetupResolvedH3Cell
}

struct DefaultStormSetupH3Resolver: StormSetupH3Resolving {
    func resolve(h3Cell rawValue: Int64) throws -> StormSetupResolvedH3Cell {
        let cell = H3Cell(UInt64(bitPattern: rawValue))
        guard cell.isValid else {
            throw Abort(
                .badRequest,
                reason: "Invalid H3 cell '\(rawValue)'. Expected a valid H3 cell encoded as a signed 64-bit integer."
            )
        }

        let center = try cell.center
        return StormSetupResolvedH3Cell(
            h3Cell: Int64(bitPattern: cell.id),
            centroid: StormSetupCentroid(
                latitude: center.latitudeDegs,
                longitude: center.longitudeDegs
            )
        )
    }
}
