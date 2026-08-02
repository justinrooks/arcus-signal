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
import ArcusCore

struct AlertDetails: Sendable, Codable {
    let title: String
    let subTitle: String
    let body: String
}

protocol NotificationSender: Sendable {
    func sendNotification(
        app: Application,
        with details: AlertDetails,
        hotAlertPayload: HotAlertAPNsPayload,
        to device: String,
        environment: APNsEnvironment
    ) async throws
}

struct APNsClient: NotificationSender {
    func sendNotification(
        app: Application,
        with details: AlertDetails,
        hotAlertPayload: HotAlertAPNsPayload,
        to device: String,
        environment: APNsEnvironment
    ) async throws {
        let topic = app.arcusAPNSConfig.topic
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
            payload: hotAlertPayload,
            badge: 0
        )
        
        try await client.sendAlertNotification(
            alert,
            deviceToken: device
        )
    }
}
