//
//  Logger+Extensions.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//

import Logging

extension Logger {
    private static func arcus(category: String) -> Logger {
        var logger = Logger(label: "arcus-signal")
        logger[metadataKey: "category"] = .string(category)
        return logger
    }

    // MARK: Plumbing
    static var providersSpcClient: Logger { arcus(category: "providers.spc.client") }
    static var networkDownloader: Logger { arcus(category: "network.downloader") }
    static var providersSpc: Logger { arcus(category: "providers.spc") }
    static var parsingRss: Logger { arcus(category: "parsing.rss") }
    static var providersNwsClient: Logger { arcus(category: "providers.nws.client") }
    static var providersNws: Logger { arcus(category: "providers.nws") }
    static var providersNwsGrid: Logger { arcus(category: "providers.nws.grid") }
    static var providersWeatherKit: Logger { arcus(category: "providers.weatherKit") }

    // MARK: Notification Delivery
    static var notificationsSender: Logger { arcus(category: "notifications.sender") }
}
