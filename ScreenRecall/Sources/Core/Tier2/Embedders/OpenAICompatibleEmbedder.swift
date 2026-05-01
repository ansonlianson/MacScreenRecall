import Foundation

/// 通过 OpenAI 兼容 /v1/embeddings 调用云端或本地 embedding 服务。
/// 例如：LM Studio 加载 bge-m3 GGUF + 启用 embedding endpoint。
struct OpenAICompatibleEmbedder: Embedder {
    let profile: ModelProfile
    let apiKey: String?
    var name: String { "openai:\(profile.model)" }
    var dim: Int { _dim }
    private let _dim: Int

    init(profile: ModelProfile, apiKey: String?, dim: Int = 1024) {
        self.profile = profile
        self.apiKey = apiKey
        self._dim = dim
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var endpoint = profile.endpoint
        while endpoint.hasSuffix("/") { endpoint.removeLast() }
        guard let url = URL(string: endpoint + "/embeddings") else {
            throw LLMProviderError.invalidEndpoint
        }
        let body: [String: Any] = [
            "model": profile.model,
            "input": texts
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = TimeInterval(profile.timeoutSec)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let http = resp as! HTTPURLResponse
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.http(status: http.statusCode, body: raw)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else {
            throw LLMProviderError.decoding("not embeddings shape: \(raw.prefix(200))")
        }
        return arr.compactMap { item -> [Float]? in
            if let v = item["embedding"] as? [Double] {
                return v.map { Float($0) }
            } else if let v = item["embedding"] as? [Float] {
                return v
            }
            return nil
        }
    }
}
