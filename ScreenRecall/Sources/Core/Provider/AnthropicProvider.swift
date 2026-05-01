import Foundation

struct AnthropicProvider: LLMProvider {
    var kind: ProviderKind { .anthropic }
    var name: String { "anthropic" }
    var supportsVision: Bool { true }

    let endpoint: String
    let apiKey: String

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard !apiKey.isEmpty else { throw LLMProviderError.missingAPIKey }
        guard let url = URL(string: trimmedEndpoint() + "/v1/messages") else {
            throw LLMProviderError.invalidEndpoint
        }

        var anthMessages: [[String: Any]] = []
        for m in request.messages {
            if m.role == .system { continue }
            if m.role == .user, !request.images.isEmpty, m == request.messages.last {
                var parts: [[String: Any]] = []
                for img in request.images {
                    parts.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": img.base64EncodedString()
                        ]
                    ])
                }
                parts.append(["type": "text", "text": m.text])
                anthMessages.append(["role": "user", "content": parts])
            } else {
                anthMessages.append(["role": m.role.rawValue, "content": m.text])
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.maxTokens,
            "messages": anthMessages,
            "temperature": request.temperature
        ]
        if let sys = request.system, !sys.isEmpty {
            body["system"] = sys
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = request.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let http = resp as! HTTPURLResponse
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw LLMProviderError.http(status: http.statusCode, body: raw)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.decoding("not json: \(raw.prefix(200))")
        }
        let usage = json["usage"] as? [String: Any]
        let tokensIn = usage?["input_tokens"] as? Int
        let tokensOut = usage?["output_tokens"] as? Int

        // content 是数组，过滤掉 thinking 块只取 text 块
        let parts = json["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { p -> String? in
            guard (p["type"] as? String) == "text" else { return nil }
            return p["text"] as? String
        }.joined()

        if text.isEmpty { throw LLMProviderError.empty }

        return LLMResponse(
            text: text,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            costUSD: nil,
            latencyMs: latency,
            raw: raw
        )
    }

    private func trimmedEndpoint() -> String {
        var s = endpoint
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
