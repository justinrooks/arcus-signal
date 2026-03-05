import Vapor

struct ReplayIngestRequest: Content {
    let fixtureName: String
    let runLabel: String?
}

