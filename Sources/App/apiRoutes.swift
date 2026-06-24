import Fluent
import FluentSQL
import Queues
import Vapor

// Api Routes
func configureAPIRoutes(_ app: Application) throws {
    try app.register(collection: HealthController())
    try app.register(collection: DevController())
    if app.arcusDebugEndpointsEnabled {
        try app.register(collection: AnvilProfilePreviewController())
        try app.register(collection: AnvilProfileAnalysisController())
    }
    try app.register(collection: NotificationsController())
    try app.register(collection: AlertsController())
    try app.register(collection: DeviceController())
    try app.register(collection: OperatorDashboardController())
    try app.register(collection: StormSetupController())
}

public func normalizedOptional(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}
