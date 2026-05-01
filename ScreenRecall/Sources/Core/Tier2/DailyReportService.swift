import Foundation
import GRDB

enum DailyReportError: Error, LocalizedError {
    case noData
    case providerFailed(String)
    var errorDescription: String? {
        switch self {
        case .noData: return "当日无可用 analyses 数据"
        case .providerFailed(let m): return "Tier-2 调用失败：\(m)"
        }
    }
}

private struct DayRow {
    var frameId: Int64
    var capturedAt: Int64
    var summary: String?
    var app: String?
    var windowTitle: String?
    var url: String?
    var activityType: String?
    var keyText: String?
    var todoCandidatesJson: String?
}

enum DailyReportService {
    /// 生成指定日期的日报，落库并写文件。返回报告 id 与 markdown。
    @discardableResult
    static func generate(for date: Date = Date()) async throws -> (Int64, String) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        let endMs = Int64(end.timeIntervalSince1970 * 1000)

        let rows: [DayRow] = try await Database.shared.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT a.frame_id, f.captured_at, a.summary, a.app, a.window_title, a.url,
                       a.activity_type, a.key_text, a.todo_candidates_json
                FROM analyses a JOIN frames f ON f.id = a.frame_id
                WHERE f.captured_at >= ? AND f.captured_at < ? AND f.analysis_status='done'
                ORDER BY f.captured_at ASC
                """, arguments: [startMs, endMs]).map { r in
                DayRow(
                    frameId: r["frame_id"], capturedAt: r["captured_at"],
                    summary: r["summary"], app: r["app"], windowTitle: r["window_title"],
                    url: r["url"], activityType: r["activity_type"], keyText: r["key_text"],
                    todoCandidatesJson: r["todo_candidates_json"]
                )
            }
        }
        guard !rows.isEmpty else { throw DailyReportError.noData }

        let buckets = bucketize(rows: rows)
        let activityShare = activityShares(rows: rows)
        let topAppList = topApps(rows: rows, n: 8)
        let allTodoCandidates = collectTodoCandidates(rows: rows)

        let context = """
        日期：\(formatDate(start))
        当日 done analyses 数：\(rows.count)
        采集时段：\(formatTime(rows.first!.capturedAt)) - \(formatTime(rows.last!.capturedAt))

        ## 时间桶（30 分钟）
        \(buckets)

        ## activity_type 占比
        \(activityShare)

        ## TOP 应用
        \(topAppList)

        ## 候选 TODO（去重前）
        \(allTodoCandidates.prefix(40).joined(separator: "\n"))
        """

        let concise = await MainActor.run { SettingsStore.shared.settings.reports.concise }
        let style = concise ? "精简：≤200字总结，仅核心。" : "详尽：包含时间线、应用占比、关键事件、可执行 TODO。"

        let system = """
        你是用户的"屏幕一日记"作者，输出 Markdown 日报。结构严格如下：

        # 今日日报 — \(formatDate(start))
        ## ① 一句话摘要
        ## ② 时间线（按时间桶）
        ## ③ activity_type 时长占比（带百分比）
        ## ④ TOP 应用 / 网站
        ## ⑤ 今日 TODO 摘要（去重过的可执行项，最多 8 条；每行以 - [ ] 开头）
        ## ⑥ 关键事件（亮点 / 异常）

        风格：\(style)
        语言：中文，简洁有信息量；不要编造数字。
        """

        let bundle = await MainActor.run { () -> (ModelProfile, String?)? in
            guard let p = SettingsStore.shared.tier2Profile() else { return nil }
            return (p, KeychainStore.get(forProfileId: p.id))
        }
        guard let (profile, apiKey) = bundle else { throw DailyReportError.providerFailed("未配置 Tier-2 模型") }
        let provider = ProviderFactory.make(profile: profile, apiKey: apiKey)
        let req = LLMRequest(
            system: system,
            messages: [LLMMessage(role: .user, text: context)],
            images: [],
            model: profile.model,
            temperature: 0.5,
            maxTokens: max(2000, profile.maxTokens),
            timeout: TimeInterval(profile.timeoutSec),
            responseFormat: .text,
            disableThinking: false
        )
        let resp: LLMResponse
        do { resp = try await provider.complete(req) }
        catch { throw DailyReportError.providerFailed(error.localizedDescription) }

        let dayStr = formatDate(start)
        try? FileManager.default.createDirectory(at: AppPaths.reportsDir, withIntermediateDirectories: true)
        let fileURL = AppPaths.reportsDir.appendingPathComponent("\(dayStr).md")
        try? resp.text.data(using: .utf8)?.write(to: fileURL)

        let row = ReportRow(
            id: nil, kind: "daily",
            rangeStart: startMs, rangeEnd: endMs,
            generatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            provider: provider.name, model: profile.model,
            markdown: resp.text,
            metaJson: jsonString([
                "frames": rows.count,
                "tokens_in": resp.tokensIn ?? 0,
                "tokens_out": resp.tokensOut ?? 0
            ])
        )
        let id = try ReportsRepository.upsert(row)
        AppLogger.tier2.info("daily report \(dayStr) generated id=\(id) latency=\(resp.latencyMs)ms")
        return (id, resp.text)
    }

    private static func bucketize(rows: [DayRow]) -> String {
        let bucketMs: Int64 = 30 * 60 * 1000
        var buckets: [Int64: [String]] = [:]
        for r in rows {
            guard let s = r.summary, !s.isEmpty else { continue }
            let bucket = (r.capturedAt / bucketMs) * bucketMs
            buckets[bucket, default: []].append("[\(formatTime(r.capturedAt))] \(s.prefix(120))")
        }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return buckets.keys.sorted().map { key in
            let t = Date(timeIntervalSince1970: TimeInterval(key) / 1000)
            let header = "**\(f.string(from: t))** ~"
            let body = buckets[key]!.prefix(8).map { "  - \($0)" }.joined(separator: "\n")
            return header + "\n" + body
        }.joined(separator: "\n\n")
    }

    private static func activityShares(rows: [DayRow]) -> String {
        var counts: [String: Int] = [:]
        for r in rows { counts[r.activityType ?? "other", default: 0] += 1 }
        let total = max(1, rows.count)
        return counts.sorted { $0.value > $1.value }
            .prefix(10)
            .map { "- \($0.key): \($0.value) (\($0.value * 100 / total)%)" }
            .joined(separator: "\n")
    }

    private static func topApps(rows: [DayRow], n: Int) -> String {
        var counts: [String: Int] = [:]
        for r in rows {
            let a = (r.app ?? "").trimmingCharacters(in: .whitespaces)
            if !a.isEmpty { counts[a, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value }
            .prefix(n)
            .map { "- \($0.key): \($0.value) 帧" }
            .joined(separator: "\n")
    }

    private static func collectTodoCandidates(rows: [DayRow]) -> [String] {
        var out: [String] = []
        for r in rows {
            guard let json = r.todoCandidatesJson?.data(using: .utf8),
                  let arr = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { continue }
            for item in arr {
                if let t = item["text"] as? String, !t.isEmpty {
                    out.append("- \(t.prefix(120))")
                }
            }
        }
        return out
    }

    private static func formatDate(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private static func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private static func jsonString(_ obj: Any) -> String? {
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
