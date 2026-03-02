import Foundation
import Vapor

struct ReplayIngestAcceptedResponse: Content {
    let status: String
    let source: String
    let fixtureName: String
    let runLabel: String?
    let queuedAt: Date
}
