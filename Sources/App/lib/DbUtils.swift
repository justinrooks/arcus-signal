//
//  DbUtils.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/24/26.
//

import Foundation

public struct DbUtils {
    
    
    public static func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        let description = String(describing: error).lowercased()
        return description.contains("duplicate key value")
        || description.contains("unique constraint")
        || description.contains("23505")
    }
}
//func isUniqueConstraintViolation(_ error: any Error) -> Bool {
//    let description = String(describing: error).lowercased()
//    return description.contains("duplicate key value")
//    || description.contains("unique constraint")
//    || description.contains("23505")
//}
