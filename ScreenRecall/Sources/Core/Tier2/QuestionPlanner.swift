import Foundation

enum AskMode: String, Codable {
    /// 仅用 metadata 聚合（"我刚才在干嘛"、"哪一天看了 X"）
    case summary
    /// 需要看原图回答（"那个视频的播放量"、"那张图里写了什么"）
    case visual
}

struct AskPlan {
    var rangeStartMs: Int64
    var rangeEndMs: Int64
    var keywords: [String]
    var mode: AskMode
    var rawQuestion: String
}

enum QuestionPlanner {
    /// 用 Tier-2 模型把自然语言问题解析成 AskPlan；失败则用规则兜底。
    static func plan(question: String) async -> AskPlan {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)

        // 先做规则兜底，再尝试 LLM 增强
        let fallback = ruleBased(question: question, now: now)

        let (settings, apiKey) = await MainActor.run {
            (SettingsStore.shared.settings.tier2, KeychainStore.get(.tier2ApiKey))
        }
        let provider = ProviderFactory.make(settings: settings, apiKey: apiKey)
        let system = """
        你是一个查询规划器。用户在询问自己 macOS 屏幕历史。
        当前时间：\(ISO8601DateFormatter().string(from: now))（毫秒时间戳 \(nowMs)）

        请输出 JSON（只输出 JSON，不要解释）：
        {
          "range_start_ms": <int64 起始毫秒时间戳>,
          "range_end_ms": <int64 结束毫秒时间戳>,
          "keywords": ["string", ...],
          "mode": "summary" | "visual"
        }

        规则：
        - "刚才/最近 N 分钟/小时" → 当前时间往回推
        - "今天/昨天/上周三下午" → 解析为对应日期区间
        - 没指定时间 → 默认最近 24 小时
        - 问"我在干嘛/做了什么/总结" → mode=summary
        - 问"画面里写的什么/数字/标题/具体细节" → mode=visual
        - keywords 是少量中文/英文搜索词（≤6 个），用于 SQLite FTS
        """
        let req = LLMRequest(
            system: system,
            messages: [LLMMessage(role: .user, text: question)],
            images: [],
            model: settings.model,
            temperature: 0.0,
            maxTokens: 256,
            timeout: 30,
            responseFormat: .json,
            disableThinking: true
        )
        do {
            let resp = try await provider.complete(req)
            if let parsed = JSONExtractor.extract(from: resp.text),
               let start = (parsed["range_start_ms"] as? NSNumber)?.int64Value,
               let end = (parsed["range_end_ms"] as? NSNumber)?.int64Value {
                let kws = (parsed["keywords"] as? [String]) ?? []
                let mode = AskMode(rawValue: (parsed["mode"] as? String) ?? "summary") ?? .summary
                AppLogger.tier2.info("plan via LLM start=\(start) end=\(end) kws=\(kws.joined(separator: ",")) mode=\(mode.rawValue)")
                return AskPlan(rangeStartMs: start, rangeEndMs: end,
                               keywords: kws, mode: mode, rawQuestion: question)
            }
        } catch {
            AppLogger.tier2.error("plan LLM failed: \(error.localizedDescription)")
        }
        return fallback
    }

    private static func ruleBased(question: String, now: Date) -> AskPlan {
        let lower = question.lowercased()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        var startMs = nowMs - 24 * 3600 * 1000

        // 简单关键词匹配
        if let m = firstMatch(in: lower, regex: "(\\d+)\\s*分钟") {
            let mins = Int(m) ?? 10
            startMs = nowMs - Int64(mins * 60 * 1000)
        } else if let m = firstMatch(in: lower, regex: "(\\d+)\\s*小时") {
            let hours = Int(m) ?? 1
            startMs = nowMs - Int64(hours * 3600 * 1000)
        } else if lower.contains("刚才") || lower.contains("最近") {
            startMs = nowMs - 30 * 60 * 1000
        } else if lower.contains("今天") {
            startMs = Int64(Calendar.current.startOfDay(for: now).timeIntervalSince1970 * 1000)
        } else if lower.contains("昨天") {
            let cal = Calendar.current
            let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now))!
            startMs = Int64(yesterday.timeIntervalSince1970 * 1000)
            return AskPlan(rangeStartMs: startMs,
                           rangeEndMs: Int64(cal.startOfDay(for: now).timeIntervalSince1970 * 1000) - 1,
                           keywords: extractKeywords(question), mode: detectMode(question),
                           rawQuestion: question)
        }

        return AskPlan(
            rangeStartMs: startMs,
            rangeEndMs: nowMs,
            keywords: extractKeywords(question),
            mode: detectMode(question),
            rawQuestion: question
        )
    }

    private static func detectMode(_ q: String) -> AskMode {
        let visualHints = ["播放量", "数字", "标题", "url", "网址", "金额", "价格",
                           "写的", "看清", "细节", "里面", "数值"]
        return visualHints.contains(where: { q.contains($0) }) ? .visual : .summary
    }

    private static func extractKeywords(_ q: String) -> [String] {
        // 用 CJKTokenizer 做中英分词；CJKTokenizer 内部已含基础停用词过滤
        return Array(CJKTokenizer.tokenize(q, minLength: 2).prefix(6))
    }

    private static func firstMatch(in text: String, regex pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
