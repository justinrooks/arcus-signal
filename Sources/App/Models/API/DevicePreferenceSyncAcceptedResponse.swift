import Foundation

struct DevicePreferenceSyncAcceptedResponse: Sendable, Codable, Equatable {
    let status: String
    let receivedAt: Date
}
