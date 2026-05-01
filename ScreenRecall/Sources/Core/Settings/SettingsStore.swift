import Foundation
import Observation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case local, openai, anthropic
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .local: return "Local (OpenAI 兼容)"
        case .openai: return "OpenAI 兼容"
        case .anthropic: return "Anthropic 兼容"
        }
    }
}

struct ProviderSettings: Codable, Equatable {
    var provider: ProviderKind
    var endpoint: String
    var model: String
    var timeoutSec: Int
    var concurrency: Int
    var temperature: Double
    var maxTokens: Int
}

struct CaptureSettings: Codable, Equatable {
    var intervalSec: Int = 30
    var jpegQuality: Int = 75
    var maxLongEdge: Int = 1600
    var skipWhenLocked: Bool = true
    var dedupPHashDistance: Int = 4
    var maxBacklog: Int = 50
    var paused: Bool = false
}

struct ReportSettings: Codable, Equatable {
    var dailyAt: String = "23:00"
    var weeklyDow: Int = 1
    var weeklyAt: String = "09:00"
    var concise: Bool = false
}

enum TodoExtractMode: String, Codable, CaseIterable, Identifiable {
    case daily2230, realtime, off
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .daily2230: return "每日 22:30"
        case .realtime: return "实时"
        case .off: return "关闭"
        }
    }
}

struct TodoSettings: Codable, Equatable {
    var extractMode: TodoExtractMode = .daily2230
    var secondaryReview: Bool = true
}

struct RetentionSettings: Codable, Equatable {
    var imagesDays: Int = 30
    var analysesDays: Int = 365
}

struct PrivacySettings: Codable, Equatable {
    var excludedBundleIds: [String] = []
    var excludedTitleRegex: [String] = []
}

struct UISettings: Codable, Equatable {
    var showInDock: Bool = false
    var launchAtLogin: Bool = true
}

struct AppSettings: Codable, Equatable {
    var capture = CaptureSettings()
    var tier1 = ProviderSettings(
        provider: .openai,
        endpoint: "https://coding.dashscope.aliyuncs.com/v1",
        model: "qwen3.6-plus",
        timeoutSec: 90,
        concurrency: 1,
        temperature: 0.2,
        maxTokens: 2048
    )
    var tier2 = ProviderSettings(
        provider: .anthropic,
        endpoint: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
        model: "qwen3.6-plus",
        timeoutSec: 180,
        concurrency: 1,
        temperature: 0.3,
        maxTokens: 4096
    )
    var reports = ReportSettings()
    var todos = TodoSettings()
    var retention = RetentionSettings()
    var privacy = PrivacySettings()
    var ui = UISettings()
}

@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private let storageKey = "recall.settings.v2"
    private let defaults = UserDefaults.standard
    private var debounceTask: Task<Void, Never>?

    var settings: AppSettings {
        didSet { scheduleSave() }
    }
    var tier1ApiKey: String = "" {
        didSet { KeychainStore.set(.tier1ApiKey, tier1ApiKey) }
    }
    var tier2ApiKey: String = "" {
        didSet { KeychainStore.set(.tier2ApiKey, tier2ApiKey) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "recall.settings.v2"),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings()
        }
        self.tier1ApiKey = KeychainStore.get(.tier1ApiKey) ?? ""
        self.tier2ApiKey = KeychainStore.get(.tier2ApiKey) ?? ""

        // 开发期便利：若 Keychain 为空且默认 endpoint 是 dashscope，预填一次开发 key
        let devKey = "sk-sp-0ce1aa0951844541af3452efc6d96649"
        if tier1ApiKey.isEmpty,
           settings.tier1.endpoint.contains("dashscope") {
            tier1ApiKey = devKey
        }
        if tier2ApiKey.isEmpty,
           settings.tier2.endpoint.contains("dashscope") {
            tier2ApiKey = devKey
        }
    }

    private func scheduleSave() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run { self?.persist() }
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: storageKey)
        AppLogger.settings.info("settings persisted")
    }
}
