//
//  APNsClient.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/9/26.
//

import Foundation
import APNS
import VaporAPNS
import APNSCore
import Vapor

// Custom Codable Payload
struct MyPayload: Codable {
    let acme1: String
    let acme2: Int
}

struct AlertDetails: Sendable, Codable {
    let title: String
    let subTitle: String
    let body: String
}

struct APNsClient {
    
    
    func sendNotification(app: Application, with details: AlertDetails, to device: String) async throws {
        // Create push notification Alert
//        let payload = MyPayload(acme1: "hey", acme2: 2)
        let alert = APNSAlertNotification(
            alert: .init(
                title: .raw(details.title),
                subtitle: .raw(details.subTitle),
                body: .raw(details.body),
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: "com.skyaware.app",
            payload: EmptyPayload(),
            badge: 0
        )
        
        // Send the notification
        try! await app.apns.client(.development).sendAlertNotification(
            alert,
            deviceToken: device
        )
    }
}
