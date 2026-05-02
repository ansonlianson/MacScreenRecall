import SwiftUI

@main
struct ScreenRecallApp: App {
    @State private var settings = SettingsStore.shared
    @State private var appState = AppState.shared

    init() {
        AppLogger.bootstrap()
        if Self.enforceSingleInstance() { return }
        AppLogger.app.info("ScreenRecall launching")
        Database.shared.bootstrap()
        Task { @MainActor in
            DebugFile.write("App init Task: refresh permissions")
            await PermissionsService.shared.refresh()
            DebugFile.write("App init Task: warm counters; auth=\(AppState.shared.screenRecordingAuthorized)")
            await Self.warmCounters()
            DebugFile.write("App init Task: starting Tier1 workers")
            await Tier1Pipeline.shared.startWorkers()
            DebugFile.write("App init Task: starting EmbeddingService")
            await EmbeddingService.shared.start()
            // 后台清理 v0.2.0 之前 dedup 留下的 skipped 帧（一次性，不阻塞 UI）
            Task.detached(priority: .background) {
                let (rows, bytes) = await CleanupService.purgeLegacySkippedFrames()
                if rows > 0 {
                    DebugFile.write("legacy skipped purged: rows=\(rows) freed=\(bytes / 1024 / 1024) MB")
                }
            }
            DebugFile.write("App init Task: starting CaptureScheduler")
            CaptureScheduler.shared.start()
            DebugFile.write("App init Task: starting Tier2Scheduler")
            Tier2Scheduler.shared.start()
            DebugFile.write("App init Task: done")
            await Self.runEnvTriggers()
        }
    }

    /// 若已有同 bundleId 实例在运行，激活它并退出本进程。返回 true 表示已退出流程。
    private static func enforceSingleInstance() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let bid = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me }
        if let other = others.first {
            other.activate(options: [.activateAllWindows])
            AppLogger.app.info("another instance pid=\(other.processIdentifier) detected, terminating self")
            NSApp?.terminate(nil)
            // NSApp 此刻可能为 nil；直接 exit 兜底。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
            return true
        }
        return false
    }

    @MainActor
    private static func runEnvTriggers() async {
        let env = ProcessInfo.processInfo.environment
        if env["SR_TRIGGER_DAILY"] == "1" {
            DebugFile.write("ENV trigger: daily report")
            do {
                let (id, md) = try await DailyReportService.generate()
                DebugFile.write("ENV daily report id=\(id) len=\(md.count)")
            } catch {
                DebugFile.write("ENV daily report failed: \(error.localizedDescription)")
            }
        }
        if let q = env["SR_TRIGGER_ASK"], !q.isEmpty {
            DebugFile.write("ENV trigger: ask q=\(q)")
            let r = await AnswerPipeline.ask(q)
            DebugFile.write("ENV ask diag: keywords=\(r.diagnostics.keywords) ftsExpr=\(r.diagnostics.ftsExpression.prefix(120)) hits=\(r.hits.count) range=\(r.plan.rangeStartMs)->\(r.plan.rangeEndMs)")
            DebugFile.write("ENV ask answer (first 400 chars): \(r.answer.prefix(400))")
        }
        if env["SR_TRIGGER_SELFCHECK"] == "1" {
            DebugFile.write("ENV trigger: self-check")
            let r = await SelfCheckService.run()
            DebugFile.write("ENV self-check screen=\(r.screenRecording) notif=\(r.notification) db=\(r.dbReachable) tier1=\(r.tier1Reachable ?? false)/\(r.tier1Latency ?? -1)ms tier2=\(r.tier2Reachable ?? false)/\(r.tier2Latency ?? -1)ms successRate=\(r.lastHourSuccessRate) framesDirBytes=\(r.framesDirBytes)")
        }
        if env["SR_TRIGGER_TODO"] == "1" {
            DebugFile.write("ENV trigger: TODO extract")
            do {
                let n = try await TodoExtractor.extract()
                DebugFile.write("ENV TODO extract inserted=\(n)")
            } catch {
                DebugFile.write("ENV TODO extract failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private static func warmCounters() async {
        let n = (try? FrameRepository.todayCount()) ?? 0
        let p = (try? FrameRepository.pendingCount()) ?? 0
        let recent = (try? AnalysisRepository.recentSummaries(limit: 5)) ?? []
        AppState.shared.todayFrameCount = n
        AppState.shared.pendingAnalysisCount = p
        AppState.shared.recentSummaries = recent
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environment(settings)
                .environment(appState)
        } label: {
            // 健康度低于 50% → 红色 eye；正常 → 默认；暂停 → eye.slash
            let symbol = appState.captureEnabled ? "eye" : "eye.slash"
            let degraded = appState.hourlySuccessRate < 0.5 && appState.captureEnabled
            Image(systemName: degraded ? "eye.trianglebadge.exclamationmark" : symbol)
        }
        .menuBarExtraStyle(.window)

        Window("Screen Recall", id: "main") {
            MainWindow()
                .environment(settings)
                .environment(appState)
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
