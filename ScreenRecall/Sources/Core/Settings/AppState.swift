import Foundation
import Observation

@Observable
final class AppState {
    static let shared = AppState()

    var captureEnabled: Bool = false
    var todayFrameCount: Int = 0
    var pendingAnalysisCount: Int = 0
    var failedAnalysisCount: Int = 0
    /// 0..1，近 1 小时分析成功率；用于菜单栏图标变色
    var hourlySuccessRate: Double = 1.0
    var lastAnalyzedAt: Date?
    var tier1HealthyRate: Double = 1.0
    var tier2HealthyRate: Double = 1.0
    var diskUsageBytes: Int64 = 0
    var screenRecordingAuthorized: Bool = false
    var notificationAuthorized: Bool = false
    var recentSummaries: [String] = []
    var lastError: String?

    private init() {}
}
