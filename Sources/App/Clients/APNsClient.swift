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
    func sendNotification(
        app: Application,
        with details: AlertDetails,
        to device: String,
        environment: APNsEnvironment
    ) async throws {
        let topic = app.arcusAPNSConfig.topic
        // Create push notification Alert
//        let payload = MyPayload(acme1: "hey", acme2: 2)
        
        
        let containerID: APNSContainers.ID = switch environment {
        case .sandbox:
            .development
        case .prod:
            .production
        }

        let client = await app.apns.client(containerID)
        
        let alert = APNSAlertNotification(
            alert: .init(
                title: .raw(details.title),
                subtitle: .raw(details.subTitle),
                body: .raw(details.body),
            ),
            expiration: .immediately,
            priority: .immediately,
            topic: topic,
            payload: EmptyPayload(),
            badge: 0
        )
        
        try await client.sendAlertNotification(
            alert,
            deviceToken: device
        )
        
//        // Send the notification
//        let env: APNSContainers.ID = environment == .sandbox ? .development : .production
//        try await app.apns.client(env).sendAlertNotification(
//            alert,
//            deviceToken: device
//        )
    }
}
