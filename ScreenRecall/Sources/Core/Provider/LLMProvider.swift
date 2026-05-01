import Foundation

enum LLMRole: String, Codable {
    case system, user, assistant
}

struct LLMMessage {
    var role: LLMRole
    var text: String
}

enum LLMResponseFormat {
    case text
    case json
}

struct LLMRequest {
    var system: String?
    var messages: [LLMMessage]
    var images: [Data]
    var model: String
    var temperature: Double
    var maxTokens: Int
    var timeout: TimeInterval
    var responseFormat: LLMResponseFormat
    var disableThinking: Bool
}

struct LLMResponse {
    let text: String
    let tokensIn: Int?
    let tokensOut: Int?
    let costUSD: Double?
    let latencyMs: Int
    let raw: String
}

protocol LLMProvider: Sendable {
    var kind: ProviderKind { get }
    var name: String { get }
    var supportsVision: Bool { get }
    func complete(_ request: LLMRequest) async throws -> LLMResponse
}

enum LLMProviderError: Error, LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case http(status: Int, body: String)
    case decoding(String)
    case empty
    case timeout

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "缺少 API Key（请到设置中填入）"
        case .invalidEndpoint: return "Endpoint URL 无效"
        case .http(let s, let b): return "HTTP \(s): \(b.prefix(200))"
        case .decoding(let m): return "响应解析失败：\(m)"
        case .empty: return "Provider 返回为空"
        case .timeout: return "请求超时"
        }
    }
}

enum ProviderFactory {
    static func make(settings: ProviderSettings, apiKey: String?) -> LLMProvider {
        switch settings.provider {
        case .local, .openai:
            return OpenAIProvider(endpoint: settings.endpoint, apiKey: apiKey, kind: settings.provider)
        case .anthropic:
            return AnthropicProvider(endpoint: settings.endpoint, apiKey: apiKey ?? "")
        }
    }
}
