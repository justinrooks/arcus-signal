//
//  Logger+Extensions.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 2/21/26.
//

import Foundation
import OSLog

extension Logger {
    static let subsystem = "Arcus-Signal"//Bundle.main.bundleIdentifier!
    
    // MARK: Plumbing
    static let providersSpcClient = Logger(subsystem: subsystem, category: "providers.spc.client")
    static let networkDownloader = Logger(subsystem: subsystem, category: "network.downloader")
    static let providersSpc = Logger(subsystem: subsystem, category: "providers.spc")
    static let parsingRss = Logger(subsystem: subsystem, category: "parsing.rss")
    static let providersNwsClient = Logger(subsystem: subsystem, category: "providers.nws.client")
    static let providersNws = Logger(subsystem: subsystem, category: "providers.nws")
    static let providersNwsGrid = Logger(subsystem: subsystem, category: "providers.nws.grid")
    static let providersWeatherKit = Logger(subsystem: subsystem, category: "providers.weatherKit")
    
    // MARK: Notification Delivery
    static let notificationsSender = Logger(subsystem: subsystem, category: "notifications.sender")
}
