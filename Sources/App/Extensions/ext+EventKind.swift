//
//  ext+EventKind.swift
//  ArcusSignal
//
//  Created by Justin Rooks on 3/10/26.
//

import Foundation

public extension EventKind {
    static func fromNwsEventName(_ eventName: String?) -> EventKind? {
        switch eventName?.normalizedLowercased {
        case "tornado warning":
            return .torWarning
        case "severe thunderstorm warning":
            return .svrTstormWarning
        case "flash flood warning":
            return .ffWarning
        case "tornado watch":
            return .torWatch
        case "severe thunderstorm watch":
            return .svrTstormWatch
        case "winter storm warning":
            return .winterStormWarning
        case "extreme fire danger":
            return .extremeFireDanger
        case "fire warning":
            return .fireWarning
        case "fire weather watch":
            return .fireWeatherWatch
        case "red flag warning":
            return .redFlagWarning
        default: // If it isn't defined here, we aren't supporting it yet.
            return nil
        }
    }
    
    static func toNwsEventName(_ eventKind: EventKind?) -> String {
        switch eventKind {
        case .torWarning:
            return "tornado warning"
        case .svrTstormWarning:
            return "severe thunderstorm warning"
        case .ffWarning:
            return "flash flood warning"
        case .torWatch:
            return "tornado watch"
        case .svrTstormWatch:
            return "severe thunderstorm watch"
        case .winterStormWarning:
            return "winter storm warning"
        case .extremeFireDanger:
            return "extreme fire danger"
        case .fireWarning:
            return "fire warning"
        case .fireWeatherWatch:
            return "fire weather watch"
        case .redFlagWarning:
            return "red flag warning"
        default: // If it isn't defined here, we aren't supporting it yet.
            return "Unknown"
        }
    }
    
    //TODO: I know there's a better way to handle this translation
    static func toNwsEventName(_ eventKind: String?) -> String {
        switch eventKind {
        case "torWarning":
            return "tornado warning"
        case "svrTstormWarning":
            return "severe thunderstorm warning"
        case "ffWarning":
            return "flash flood warning"
        case "torWatch":
            return "tornado watch"
        case "svrTstormWatch":
            return "severe thunderstorm watch"
        case "winterStormWarning":
            return "winter storm warning"
        case "extremeFireDanger":
            return "extreme fire danger"
        case "fireWarning":
            return "fire warning"
        case "fireWeatherWatch":
            return "fire weather watch"
        case "redFlagWarning":
            return "red flag warning"
        default: // If it isn't defined here, we aren't supporting it yet.
            return "Unknown"
        }
    }
}
