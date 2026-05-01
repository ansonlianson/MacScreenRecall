import Foundation

struct OpenAIProvider: LLMProvider {
    let kind: ProviderKind
    var name: String { kind == .local ? "lmstudio" : "openai" }
    var supportsVision: Bool { true }

    let endpoint: String
    let apiKey: String?

    init(endpoint: String, apiKey: String?, kind: ProviderKind) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.kind = kind
    }

    func complete(_ request: LLMRequest) async throws -> LLMResponse {
        guard let url = URL(string: trimmedEndpoint() + "/chat/completions") else {
            throw LLMProviderError.invalidEndpoint
        }

        var messages: [[String: Any]] = []
        if let sys = request.system, !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in request.messages {
            if m.role == .user, !request.images.isEmpty, m == request.messages.last {
                var parts: [[String: Any]] = [["type": "text", "text": m.text]]
                for img in request.images {
                    let b64 = img.base64EncodedString()
                    parts.append([
                        "type": "image_url",
                        "image_url": ["url": "data:image/jpeg;base64,\(b64)"]
                    ])
                }
                messages.append(["role": m.role.rawValue, "content": parts])
            } else {
                messages.append(["role": m.role.rawValue, "content": m.text])
            }
        }

        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "max_tokens": request.maxTokens,
            "temperature": request.temperature
        ]
        if request.disableThinking { body["enable_thinking"] = false }
        if request.responseFormat == .json {
            body["response_format"] = ["type": "json_object"]
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = request.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if kind != .local {
            throw LLMProviderError.missingAPIKey
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            DebugFile.write("OpenAI URLSession threw: \(error.localizedDescription)")
            throw error
        }
        let latency = Int(Date().timeIntervalSince(start) * 1000)
        let http = resp as! HTTPURLResponse
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            DebugFile.write("OpenAI HTTP \(http.statusCode) body=\(raw.prefix(200))")
            throw LLMProviderError.http(status: http.statusCode, body: raw)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMProviderError.decoding("not json: \(raw.prefix(200))")
        }

        let usage = json["usage"] as? [String: Any]
        let tokensIn = usage?["prompt_tokens"] as? Int
        let tokensOut = usage?["completion_tokens"] as? Int

        guard let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else {
            throw LLMProviderError.empty
        }

        let content: String
        if let s = message["content"] as? String, !s.isEmpty {
            content = s
        } else if let arr = message["content"] as? [[String: Any]] {
            content = arr.compactMap { $0["text"] as? String }.joined()
        } else {
            throw LLMProviderError.empty
        }

        return LLMResponse(
            text: content,
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

extension LLMMessage: Equatable {
    static func == (lhs: LLMMessage, rhs: LLMMessage) -> Bool {
        lhs.role == rhs.role && lhs.text == rhs.text
    }
}
