import Foundation

struct DevicePreferenceSyncRequestPayload: Sendable, Codable, Equatable {
    let installationId: String
    let apnsDeviceToken: String
    let apnsEnvironment: String
    let platform: String
    let osVersion: String
    let appVersion: String
    let buildNumber: String
    let auth: String
    let isSubscribed: Bool
    let source: String
    let reason: String
}
