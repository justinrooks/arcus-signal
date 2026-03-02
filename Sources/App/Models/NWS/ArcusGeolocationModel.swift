//
//  ArcusGeolocationModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/28/26.
//

import Fluent
import Foundation


public final class ArcusGeolocationModel: Model, @unchecked Sendable {
    public static let schema = "arcus_geolocation"
    
    // MARK: Identity
    @ID(key: .id)
    public var id: UUID?
    
    @Parent(key: "series_id")
    public var series: ArcusSeriesModel
    
    @Field(key: "geometry")
    public var geometry: GeoShape
    
    // Stable hash of geometry payload (normalized or raw)
    @Field(key: "geometry_hash")
    var geometryHash: String
    
    // --- H3 cover ---
    // Store H3 cells as BIGINT[]; in Swift use [Int64].
    @Field(key: "h3_cells")
    var h3Cells: [Int64]
    
    // Resolution used to generate the cover (0...15 fits in Int16)
    @Field(key: "h3_resolution")
    var h3Resolution: Int16
    
    // Hash of the cell set for quick "did it change?"
    @Field(key: "h3_hash")
    var h3Hash: String
    
    // When this object was created.
    @Timestamp(key: "created", on: .create)
    var created: Date?
    
    // When this object was last updated.
    @Timestamp(key: "updated", on: .update)
    var updated: Date?
    
    // MARK: Inits
    public init() {}
    
    public init(
        id: UUID? = nil,
        series: UUID,
        geometry: GeoShape,
        geometryHash: String,
        h3Cells: [Int64],
        h3Resolution: Int16,
        h3Hash: String
    ) {
        self.id = id
        self.$series.id = series
        self.geometry = geometry
        self.geometryHash = geometryHash
        self.h3Cells = h3Cells
        self.h3Resolution = h3Resolution
        self.h3Hash = h3Hash
    }
    
}
