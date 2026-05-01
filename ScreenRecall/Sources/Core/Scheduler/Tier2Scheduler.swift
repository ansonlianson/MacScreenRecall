import Foundation

/// 轻量级调度器：每分钟 tick；按 Settings 中的 daily/weekly/todos 触发时间执行 Tier-2 任务。
/// 配合记录 lastDailyKey 等防重复触发。
@MainActor
final class Tier2Scheduler {
    static let shared = Tier2Scheduler()
    private init() {}

    private var timer: Timer?
    private var running = false

    private var lastDailyDay: String = ""        // yyyy-MM-dd
    private var lastWeeklyKey: String = ""       // yyyy-Www
    private var lastTodoKey: String = ""

    private var isDailyRunning = false
    private var isTodoRunning = false
    private var isWeeklyRunning = false

    func start() {
        guard !running else { return }
        running = true
        // 每 30 秒 tick 一次（兼顾延迟与精度）
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        AppLogger.scheduler.info("Tier2Scheduler started")
        // 启动时立刻 tick 一次（防止冷启动错过时间点）
        Task { @MainActor in self.tick() }
    }

    func stop() {
        running = false
        timer?.invalidate(); timer = nil
    }

    private func tick() {
        let s = SettingsStore.shared.settings
        let now = Date()
        let cal = Calendar.current

        // 1) 日报
        if matchesTime(now: now, hhmm: s.reports.dailyAt, gracePeriodSec: 90) {
            let key = dayKey(now)
            if key != lastDailyDay && !isDailyRunning {
                lastDailyDay = key
                isDailyRunning = true
                Task {
                    do {
                        let (_, md) = try await DailyReportService.generate(for: now)
                        AppLogger.scheduler.info("auto daily report ok len=\(md.count)")
                        AppNotifier.post(title: "今日日报已生成", body: "Markdown 长度 \(md.count) 字 · 在「报告」Tab 查看")
                    } catch {
                        AppLogger.scheduler.error("auto daily report failed: \(error.localizedDescription)")
                        AppNotifier.post(title: "日报生成失败", body: error.localizedDescription)
                    }
                    await MainActor.run { self.isDailyRunning = false }
                }
            }
        }

        // 2) 周报（每周 weeklyDow 09:00）
        if cal.component(.weekday, from: now) == s.reports.weeklyDow,
           matchesTime(now: now, hhmm: s.reports.weeklyAt, gracePeriodSec: 90) {
            let key = weekKey(now)
            if key != lastWeeklyKey && !isWeeklyRunning {
                lastWeeklyKey = key
                isWeeklyRunning = true
                Task {
                    AppLogger.scheduler.info("auto weekly report (TODO: implement)")
                    await MainActor.run { self.isWeeklyRunning = false }
                }
            }
        }

        // 自定义计划任务
        Task {
            let tasks = (try? ScheduledTasksRepository.list()) ?? []
            for t in tasks where t.isEnabled {
                if CronLite.shouldFireNow(cron: t.cron, lastRunAt: t.lastRunAt, now: now) {
                    AppLogger.scheduler.info("scheduled task fire: \(t.name) cron=\(t.cron)")
                    do {
                        _ = try await ScheduledTaskRunner.run(t)
                    } catch {
                        ScheduledTasksRepository.setLastRun(id: t.id ?? 0, at: Int64(now.timeIntervalSince1970 * 1000), status: "fail: \(error.localizedDescription)")
                        AppLogger.scheduler.error("scheduled task \(t.name) failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        // 3) TODO 抽取（仅 daily2230 模式生效）
        if s.todos.extractMode == .daily2230,
           matchesTime(now: now, hhmm: "22:30", gracePeriodSec: 90) {
            let key = dayKey(now)
            if key != lastTodoKey && !isTodoRunning {
                lastTodoKey = key
                isTodoRunning = true
                Task {
                    do {
                        let n = try await TodoExtractor.extract()
                        AppLogger.scheduler.info("auto TODO extract ok inserted=\(n)")
                        if n >= 3 {
                            AppNotifier.post(title: "今日 TODO 抽取完成", body: "新增 \(n) 条，去 TODO Tab 查看")
                        }
                    } catch {
                        AppLogger.scheduler.error("auto TODO extract failed: \(error.localizedDescription)")
                    }
                    await MainActor.run { self.isTodoRunning = false }
                }
            }
        }
    }

    private func matchesTime(now: Date, hhmm: String, gracePeriodSec: Int) -> Bool {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return false }
        let cal = Calendar.current
        var comp = cal.dateComponents([.year, .month, .day], from: now)
        comp.hour = h; comp.minute = m; comp.second = 0
        guard let target = cal.date(from: comp) else { return false }
        let diff = abs(now.timeIntervalSince(target))
        return diff <= TimeInterval(gracePeriodSec)
    }

    private func dayKey(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    private func weekKey(_ d: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let y = cal.component(.yearForWeekOfYear, from: d)
        let w = cal.component(.weekOfYear, from: d)
        return "\(y)-W\(w)"
    }
}
