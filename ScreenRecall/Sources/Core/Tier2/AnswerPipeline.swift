import Foundation

struct AskResult {
    let answer: String
    let plan: AskPlan
    let hits: [RetrievedHit]
    let usedVision: Bool
    let degraded: Bool   // true 表示问的是画面细节但模型不支持视觉，降级为 metadata
    let provider: String
    let model: String
    let latencyMs: Int
    let tokensIn: Int?
    let tokensOut: Int?
}

enum AnswerPipeline {
    static func ask(_ question: String, topK: Int = 3) async -> AskResult {
        let plan = await QuestionPlanner.plan(question: question)
        let hits = (try? Retriever.retrieve(plan: plan, limit: 20)) ?? []

        let (settings, apiKey) = await MainActor.run {
            (SettingsStore.shared.settings.tier2, KeychainStore.get(.tier2ApiKey))
        }
        let provider = ProviderFactory.make(settings: settings, apiKey: apiKey)
        let supportsVision = provider.supportsVision
        // 启发：模型名含 vl/vision/opus/sonnet/gpt-4o/claude → 视为支持视觉
        let modelLower = settings.model.lowercased()
        // qwen3.6+ / qwen2.5-vl / Claude 4.x sonnet+ / GPT-4o 都支持视觉
        let modelLooksVisual = ["vl", "vision", "opus", "sonnet", "gpt-4o", "gpt-4.1", "claude",
                                "qwen3", "qwen-3", "qwen2.5", "qwen2-5"]
            .contains(where: modelLower.contains)
        let canVision = supportsVision && modelLooksVisual
        let wantVision = plan.mode == .visual
        let useVision = wantVision && canVision

        if hits.isEmpty {
            return AskResult(
                answer: "未在指定时间窗内找到相关记录。",
                plan: plan, hits: [], usedVision: false, degraded: false,
                provider: provider.name, model: settings.model,
                latencyMs: 0, tokensIn: nil, tokensOut: nil
            )
        }

        let context = formatContext(hits: hits)
        let topImages: [Data] = useVision
            ? Array(hits.prefix(topK)).compactMap { try? Data(contentsOf: URL(fileURLWithPath: $0.frame.imagePath)) }
            : []
        let mode = useVision ? "VISUAL（带原图）" : "SUMMARY（仅 metadata）"
        let system = """
        你是用户的"屏幕记忆助手"。下面是用户最近 macOS 屏幕的若干分析记录（按时间倒序）。
        - 用中文简洁、直接回答用户的问题
        - 引用具体时间点（HH:mm 即可）
        - 若问的是画面细节（数字/标题/网址），优先从原图（如附）或 visible_numbers/key_text 中提取
        - 不知道就直说"未找到"，不要编造
        - 模式：\(mode)
        """
        let userMsg: String
        if useVision {
            userMsg = """
            问题：\(question)

            候选记录（已附最相关的 \(topImages.count) 张原图）：
            \(context)
            """
        } else {
            userMsg = """
            问题：\(question)

            候选记录：
            \(context)
            """
        }

        let req = LLMRequest(
            system: system,
            messages: [LLMMessage(role: .user, text: userMsg)],
            images: topImages,
            model: settings.model,
            temperature: settings.temperature,
            maxTokens: max(800, settings.maxTokens),
            timeout: TimeInterval(settings.timeoutSec),
            responseFormat: .text,
            disableThinking: false
        )

        do {
            let resp = try await provider.complete(req)
            return AskResult(
                answer: resp.text,
                plan: plan, hits: hits,
                usedVision: useVision,
                degraded: wantVision && !canVision,
                provider: provider.name, model: settings.model,
                latencyMs: resp.latencyMs, tokensIn: resp.tokensIn, tokensOut: resp.tokensOut
            )
        } catch {
            return AskResult(
                answer: "Tier-2 调用失败：\(error.localizedDescription)",
                plan: plan, hits: hits,
                usedVision: false, degraded: wantVision && !canVision,
                provider: provider.name, model: settings.model,
                latencyMs: 0, tokensIn: nil, tokensOut: nil
            )
        }
    }

    private static func formatContext(hits: [RetrievedHit]) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return hits.prefix(20).enumerated().map { (idx, hit) -> String in
            let t = Date(timeIntervalSince1970: TimeInterval(hit.frame.capturedAt) / 1000)
            let summary = hit.analysis.summary ?? ""
            let app = hit.analysis.app ?? ""
            let nums = hit.analysis.numbersJson ?? ""
            let key = (hit.analysis.keyText ?? "").prefix(120)
            return """
            [\(idx + 1)] \(f.string(from: t)) | app=\(app)
              summary: \(summary)
              numbers: \(nums.prefix(120))
              key_text: \(key)
            """
        }.joined(separator: "\n")
    }
}
