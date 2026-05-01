import Foundation
import GRDB

struct ScheduledTaskRow: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "scheduled_tasks"
    var id: Int64?
    var name: String
    var cron: String              // 简化语法：见 ScheduledTaskRunner
    var prompt: String
    var outputKind: String        // 'report' | 'todo' | 'notification'
    var enabled: Int64
    var lastRunAt: Int64?
    var lastStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, name, cron, prompt
        case outputKind = "output_kind"
        case enabled
        case lastRunAt = "last_run_at"
        case lastStatus = "last_status"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var isEnabled: Bool { (enabled != 0) }
}

enum ScheduledTasksRepository {
    @discardableResult
    static func upsert(_ row: ScheduledTaskRow) throws -> Int64 {
        try Database.shared.pool.write { db in
            var r = row
            try r.save(db)
            return r.id ?? 0
        }
    }

    static func list() throws -> [ScheduledTaskRow] {
        try Database.shared.pool.read { db in
            try ScheduledTaskRow.order(sql: "id ASC").fetchAll(db)
        }
    }

    static func delete(id: Int64) {
        do {
            try Database.shared.pool.write { db in
                try db.execute(sql: "DELETE FROM scheduled_tasks WHERE id=?", arguments: [id])
            }
        } catch {
            AppLogger.scheduler.error("delete scheduled task failed: \(error.localizedDescription)")
        }
    }

    static func setLastRun(id: Int64, at ms: Int64, status: String) {
        do {
            try Database.shared.pool.write { db in
                try db.execute(sql: "UPDATE scheduled_tasks SET last_run_at=?, last_status=? WHERE id=?",
                               arguments: [ms, status, id])
            }
        } catch {
            AppLogger.scheduler.error("setLastRun failed: \(error.localizedDescription)")
        }
    }
}

/// Cron-lite 语法：
/// - "daily HH:MM" — 每天指定时间
/// - "weekly D HH:MM" — 每周第 D 天（1=周一 … 7=周日）
/// - "hourly:N" — 每 N 小时（从启动算）
/// - "manual" — 不自动触发
enum CronLite {
    static func shouldFireNow(cron: String, lastRunAt: Int64?, now: Date = .init()) -> Bool {
        let s = cron.trimmingCharacters(in: .whitespaces).lowercased()
        if s == "manual" { return false }
        let cal = Calendar.current

        if s.hasPrefix("daily ") {
            let hhmm = String(s.dropFirst(6))
            return matchesHHMM(hhmm: hhmm, now: now, lastRunAt: lastRunAt, intervalSec: 24 * 3600)
        }
        if s.hasPrefix("weekly ") {
            let parts = s.dropFirst(7).split(separator: " ")
            guard parts.count == 2, let dow = Int(parts[0]) else { return false }
            // Calendar 用 1=Sun, 7=Sat（默认）；我们用 1=Mon...7=Sun
            let cur = cal.component(.weekday, from: now)
            // 1=Mon → Calendar 2; 7=Sun → Calendar 1
            let mapped = dow == 7 ? 1 : (dow + 1)
            if cur != mapped { return false }
            return matchesHHMM(hhmm: String(parts[1]), now: now, lastRunAt: lastRunAt, intervalSec: 7 * 24 * 3600)
        }
        if s.hasPrefix("hourly:") {
            guard let n = Int(s.dropFirst(7)), n > 0 else { return false }
            let interval = TimeInterval(n * 3600)
            if let last = lastRunAt {
                let lastDate = Date(timeIntervalSince1970: TimeInterval(last) / 1000)
                return now.timeIntervalSince(lastDate) >= interval
            }
            return true
        }
        return false
    }

    /// 90s 容忍窗口；并且如果今天/本周已经跑过则跳过
    private static func matchesHHMM(hhmm: String, now: Date, lastRunAt: Int64?, intervalSec: Int) -> Bool {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        let cal = Calendar.current
        var comp = cal.dateComponents([.year, .month, .day], from: now)
        comp.hour = h; comp.minute = m
        guard let target = cal.date(from: comp) else { return false }
        if abs(now.timeIntervalSince(target)) > 90 { return false }
        if let last = lastRunAt {
            let lastDate = Date(timeIntervalSince1970: TimeInterval(last) / 1000)
            if now.timeIntervalSince(lastDate) < TimeInterval(intervalSec - 600) { return false }
        }
        return true
    }
}

private struct ScopedRow {
    var capturedAt: Int64
    var summary: String?
    var app: String?
    var keyText: String?
    var activityType: String?
}

enum ScheduledTaskRunner {
    /// 立即执行一次任务：拉取最近 24h 的 done analyses 作为输入，喂给 Tier-2 + 用户 prompt，按 output_kind 路由。
    @discardableResult
    static func run(_ task: ScheduledTaskRow, windowHours: Int = 24) async throws -> String {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let startMs = nowMs - Int64(windowHours) * 3600_000

        let rows: [ScopedRow] = try await Database.shared.pool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.captured_at, a.summary, a.app, a.key_text, a.activity_type
                FROM analyses a JOIN frames f ON f.id = a.frame_id
                WHERE f.captured_at >= ? AND f.analysis_status='done'
                ORDER BY f.captured_at ASC
                """, arguments: [startMs]).map { r in
                ScopedRow(
                    capturedAt: r["captured_at"], summary: r["summary"],
                    app: r["app"], keyText: r["key_text"], activityType: r["activity_type"]
                )
            }
        }
        let context = rows.suffix(120).map { r -> String in
            let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
            let t = Date(timeIntervalSince1970: TimeInterval(r.capturedAt) / 1000)
            return "[\(f.string(from: t))] app=\(r.app ?? "") activity=\(r.activityType ?? "") | \(r.summary ?? "")"
        }.joined(separator: "\n")

        let systemBase = """
        你是用户的"屏幕记忆助手"，将根据用户自定义的指令在屏幕历史上执行任务。
        语言：中文；信息有据可依，不编造。任务名："\(task.name)"。
        """
        let outputHint: String
        switch task.outputKind {
        case "todo":
            outputHint = "输出 JSON：{\"items\":[{\"text\":\"...\",\"due_at\":<int64ms 可选>}]}（仅 JSON）。"
        case "notification":
            outputHint = "输出 1-3 行通知文案（≤200 字总）。"
        default:
            outputHint = "输出 Markdown 报告，结构清晰。"
        }
        let userMsg = """
        指令：\(task.prompt)

        最近 \(windowHours) 小时的屏幕活动：
        \(context)

        输出要求：\(outputHint)
        """

        let (settings, apiKey) = await MainActor.run {
            (SettingsStore.shared.settings.tier2, KeychainStore.get(.tier2ApiKey))
        }
        let provider = ProviderFactory.make(settings: settings, apiKey: apiKey)
        let req = LLMRequest(
            system: systemBase,
            messages: [LLMMessage(role: .user, text: userMsg)],
            images: [],
            model: settings.model,
            temperature: 0.4,
            maxTokens: max(1500, settings.maxTokens),
            timeout: TimeInterval(settings.timeoutSec),
            responseFormat: task.outputKind == "todo" ? .json : .text,
            disableThinking: false
        )
        let resp = try await provider.complete(req)
        let text = resp.text

        switch task.outputKind {
        case "todo":
            let items = parseTodoItems(json: text)
            for it in items {
                _ = try? TodosRepository.insert(TodoRow(
                    id: nil, text: it.text, sourceFrameId: nil,
                    detectedAt: nowMs, dueAt: it.dueAt, status: "open",
                    notes: "by 计划任务：\(task.name)"
                ))
            }
            ScheduledTasksRepository.setLastRun(id: task.id ?? 0, at: nowMs, status: "ok(\(items.count) todos)")
            return "插入 \(items.count) 条 TODO"

        case "notification":
            AppNotifier.post(title: task.name, body: text.prefix(200).description)
            ScheduledTasksRepository.setLastRun(id: task.id ?? 0, at: nowMs, status: "ok(notification)")
            return text

        default: // report
            let row = ReportRow(
                id: nil, kind: "custom",
                rangeStart: startMs, rangeEnd: nowMs,
                generatedAt: nowMs,
                provider: provider.name, model: settings.model,
                markdown: text,
                metaJson: jsonString(["task": task.name, "tokens_in": resp.tokensIn ?? 0, "tokens_out": resp.tokensOut ?? 0])
            )
            _ = try ReportsRepository.upsert(row)
            ScheduledTasksRepository.setLastRun(id: task.id ?? 0, at: nowMs, status: "ok(report)")
            return text
        }
    }

    private struct TodoItem { var text: String; var dueAt: Int64? }
    private static func parseTodoItems(json: String) -> [TodoItem] {
        guard let parsed = JSONExtractor.extract(from: json),
              let items = parsed["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> TodoItem? in
            guard let t = (item["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !t.isEmpty else { return nil }
            return TodoItem(text: t, dueAt: (item["due_at"] as? NSNumber)?.int64Value)
        }
    }

    private static func jsonString(_ obj: Any) -> String? {
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }
}
