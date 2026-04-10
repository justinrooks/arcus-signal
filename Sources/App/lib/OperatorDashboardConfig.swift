import Foundation

public enum OperatorDashboardConfig {
    public static let rollingWindowHours = 24

    public static let ingestRecentAttemptLimit = 60
    public static let claimedStuckThresholdSeconds = 5 * 60
    public static let staleActiveSeriesGraceSeconds = 15 * 60

    public static let installationFreshnessThresholdSeconds = 24 * 60 * 60
    public static let presenceFreshnessThresholdSeconds = 6 * 60 * 60

    public static let fastRefreshIntervalSeconds = 30
    public static let standardRefreshIntervalSeconds = 60
    public static let slowRefreshIntervalSeconds = 5 * 60

    public static let recentNotificationDebugLimit = 5
    public static let touchedSeriesLimit = 5
    public static let topFailureReasonLimit = 3
}
