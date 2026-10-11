import Fluent
import Foundation

/// Geometry is available before coverage; nil H3 metadata means not computed.
final class SPCMesoGeolocationModel: Model, @unchecked Sendable {
    static let schema = "spc_meso_geolocation"

    @ID(key: .id) var id: UUID?
    @Parent(key: "meso_id") var meso: SPCMesoModel
    @Field(key: "geometry") var geometry: GeoShape
    @Field(key: "geometry_hash") var geometryHash: String
    @Field(key: "h3_cells") var h3Cells: [Int64]
    @OptionalField(key: "h3_resolution") var h3Resolution: Int16?
    @OptionalField(key: "h3_hash") var h3Hash: String?

    init() {}

    init(mesoID: UUID, geometry: GeoShape, geometryHash: String) {
        self.$meso.id = mesoID
        self.geometry = geometry
        self.geometryHash = geometryHash
        self.h3Cells = []
        self.h3Resolution = nil
        self.h3Hash = nil
    }
}
