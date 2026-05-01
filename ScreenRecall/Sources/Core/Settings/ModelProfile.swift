import Foundation

enum EndpointKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case openaiCompatible
    case anthropicCompatible
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openaiCompatible: return "OpenAI 兼容"
        case .anthropicCompatible: return "Anthropic 兼容"
        }
    }
    var hint: String {
        switch self {
        case .openaiCompatible:
            return "适用于 OpenAI / DashScope / LM Studio / Ollama / 任何提供 /v1/chat/completions 与 /v1/embeddings 的端点"
        case .anthropicCompatible:
            return "适用于 Anthropic API 与 DashScope `/apps/anthropic` 等"
        }
    }
}

enum ModelKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case chat
    case embedding
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .chat: return "对话 (chat)"
        case .embedding: return "嵌入 (embedding)"
        }
    }
}

/// 用户在 Settings 里增删的"模型条目"。Tier-1 / Tier-2 / Embedding 三个用途各自引用一条 profile id。
/// API Key 不存这里，存 Keychain（account = "model.\(id.uuidString)"）。
struct ModelProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var endpointKind: EndpointKind
    var endpoint: String
    var model: String
    var kind: ModelKind
    var maxTokens: Int
    var timeoutSec: Int

    init(id: UUID = UUID(),
         name: String,
         endpointKind: EndpointKind,
         endpoint: String,
         model: String,
         kind: ModelKind = .chat,
         maxTokens: Int = 2048,
         timeoutSec: Int = 90) {
        self.id = id
        self.name = name
        self.endpointKind = endpointKind
        self.endpoint = endpoint
        self.model = model
        self.kind = kind
        self.maxTokens = maxTokens
        self.timeoutSec = timeoutSec
    }
}
