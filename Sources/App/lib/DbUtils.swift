//
//  DbUtils.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/24/26.
//

import Foundation

public struct DbUtils {
    
    
    public static func isUniqueConstraintViolation(_ error: any Error) -> Bool {
        let descriptions = [
            String(describing: error),
            String(reflecting: error)
        ].map { $0.lowercased() }

        return descriptions.contains(where: { description in
            description.contains("duplicate key value")
            || description.contains("duplicate key")
            || description.contains("unique constraint")
            || description.contains("23505")
        })
    }
}
//func isUniqueConstraintViolation(_ error: any Error) -> Bool {
//    let description = String(describing: error).lowercased()
//    return description.contains("duplicate key value")
//    || description.contains("unique constraint")
//    || description.contains("23505")
//}
