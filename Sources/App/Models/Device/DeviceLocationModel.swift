//
//  DeviceLocationModel.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/23/26.
//

import Fluent
import Foundation

public final class DeviceLocationModel: Model, @unchecked Sendable {
    public static let schema = "arcus_device_location"
    
    @ID(key: .id)
    public var id: UUID?
    
    public init() {}
    
    public init(
        id: UUID?
    ) {
        self.id = id
    }
}

//public extension DeviceLocationModel {
//    convenience init(from snapshot: LocationSnapshotPushPayload) throws {
//        
//        if let uuid = UUID(uuidString: snapshot.installationId) {
//            print("Valid UUID: \(uuid)")
//        } else {
//            print("Invalid UUID string")
//        }
//        
//        self.init(
//            id: uuid
//        )
//    }
//}
