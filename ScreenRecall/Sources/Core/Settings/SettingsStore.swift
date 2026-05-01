import Foundation
import Observation

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
    var profiles: [ModelProfile] = []
    var tier1ProfileId: UUID? = nil
    var tier2ProfileId: UUID? = nil
    var embeddingProfileId: UUID? = nil   // nil → 用 AppleNL 兜底
    var tier1Concurrency: Int = 1         // 取代旧 ProviderSettings.concurrency
    var reports = ReportSettings()
    var todos = TodoSettings()
    var retention = RetentionSettings()
    var privacy = PrivacySettings()
    var ui = UISettings()

    static func makeDefault() -> AppSettings {
        var s = AppSettings()
        let openai = ModelProfile(
            name: "DashScope · qwen3.6-plus (chat, OpenAI 兼容)",
            endpointKind: .openaiCompatible,
            endpoint: "https://coding.dashscope.aliyuncs.com/v1",
            model: "qwen3.6-plus",
            kind: .chat,
            maxTokens: 2048,
            timeoutSec: 90
        )
        let anthropic = ModelProfile(
            name: "DashScope · qwen3.6-plus (chat, Anthropic 兼容)",
            endpointKind: .anthropicCompatible,
            endpoint: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            model: "qwen3.6-plus",
            kind: .chat,
            maxTokens: 4096,
            timeoutSec: 180
        )
        s.profiles = [openai, anthropic]
        s.tier1ProfileId = openai.id
        s.tier2ProfileId = anthropic.id
        return s
    }
}

@Observable
final class SettingsStore {
    static let shared = SettingsStore()

    private let storageKey = "recall.settings.v3"
    private let defaults = UserDefaults.standard
    private var debounceTask: Task<Void, Never>?

    var settings: AppSettings {
        didSet { scheduleSave() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "recall.settings.v3"),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = AppSettings.makeDefault()
        }
        seedDevKeysIfNeeded()
    }

    /// 开发期便利：若 dashscope profile 还没 key，预填一次开发 key。
    private func seedDevKeysIfNeeded() {
        let devKey = "sk-sp-0ce1aa0951844541af3452efc6d96649"
        for p in settings.profiles where p.endpoint.contains("dashscope") {
            if KeychainStore.get(forProfileId: p.id) == nil {
                KeychainStore.set(forProfileId: p.id, value: devKey)
            }
        }
    }

    // MARK: - profile helpers

    func profile(id: UUID?) -> ModelProfile? {
        guard let id else { return nil }
        return settings.profiles.first(where: { $0.id == id })
    }
    func tier1Profile() -> ModelProfile? { profile(id: settings.tier1ProfileId) }
    func tier2Profile() -> ModelProfile? { profile(id: settings.tier2ProfileId) }
    func embeddingProfile() -> ModelProfile? { profile(id: settings.embeddingProfileId) }

    func upsertProfile(_ p: ModelProfile) {
        if let i = settings.profiles.firstIndex(where: { $0.id == p.id }) {
            settings.profiles[i] = p
        } else {
            settings.profiles.append(p)
        }
    }

    /// 删除 profile：同步清 Keychain；并把指向它的 tier1/tier2/embedding 置 nil
    func deleteProfile(id: UUID) {
        settings.profiles.removeAll(where: { $0.id == id })
        KeychainStore.delete(forProfileId: id)
        if settings.tier1ProfileId == id { settings.tier1ProfileId = nil }
        if settings.tier2ProfileId == id { settings.tier2ProfileId = nil }
        if settings.embeddingProfileId == id { settings.embeddingProfileId = nil }
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
        let n = self.settings.profiles.count
        AppLogger.settings.info("settings persisted (profiles=\(n))")
    }
}
