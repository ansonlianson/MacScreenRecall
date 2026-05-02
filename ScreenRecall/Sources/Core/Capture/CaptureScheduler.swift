import Foundation
import AppKit
import CoreGraphics

@MainActor
final class CaptureScheduler {
    static let shared = CaptureScheduler()
    private init() {}

    private var timer: DispatchSourceTimer?
    private var observer: NSObjectProtocol?
    private var settingsObserver: Task<Void, Never>?
    private var lastIntervalSec: Int = 0
    private var lastPaused: Bool = true
    private var running: Bool = false

    /// 锁屏状态。由 distributed notification 驱动；启动时用 CGSession 同步一次。
    private var screenLocked: Bool = false
    private var lockObservers: [NSObjectProtocol] = []

    func start() {
        guard !running else { return }
        running = true
        DebugFile.write("CaptureScheduler.start() called")
        attachWakeObserver()
        attachLockObservers()
        // 同步一次当前状态（防止启动时已经锁屏）
        screenLocked = currentCGSessionLocked()
        observeSettings()
        applyConfig(force: true)
        DebugFile.write("CaptureScheduler started, paused=\(SettingsStore.shared.settings.capture.paused) intervalSec=\(SettingsStore.shared.settings.capture.intervalSec) initialLocked=\(screenLocked)")
    }

    func stop() {
        running = false
        timer?.cancel()
        timer = nil
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        observer = nil
        for o in lockObservers {
            DistributedNotificationCenter.default().removeObserver(o)
        }
        lockObservers.removeAll()
        settingsObserver?.cancel()
        settingsObserver = nil
        AppState.shared.captureEnabled = false
        AppLogger.capture.info("CaptureScheduler stopped")
    }

    /// 监听 com.apple.screenIsLocked / Unlocked 这两个 distributed notification
    /// 是 macOS 上检测锁屏最权威的方式（loginwindow 会发）。
    private func attachLockObservers() {
        let center = DistributedNotificationCenter.default()
        let lockObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenLocked = true
                DebugFile.write("screen locked (distributed notification)")
            }
        }
        let unlockObs = center.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.screenLocked = false
                DebugFile.write("screen unlocked (distributed notification)")
            }
        }
        lockObservers = [lockObs, unlockObs]
    }

    private func attachWakeObserver() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                AppLogger.capture.info("system woke; rescheduling capture")
                self?.applyConfig(force: true)
            }
        }
    }

    private func observeSettings() {
        // Poll-based observation: recheck every 1s for interval/pause/concurrency changes
        settingsObserver?.cancel()
        settingsObserver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self?.applyConfig(force: false) }
                await Tier1Pipeline.shared.reconcileWorkers()
            }
        }
    }

    private func applyConfig(force: Bool) {
        let s = SettingsStore.shared.settings.capture
        let interval = max(5, min(600, s.intervalSec))
        let paused = s.paused
        if !force && interval == lastIntervalSec && paused == lastPaused { return }
        lastIntervalSec = interval
        lastPaused = paused

        timer?.cancel()
        timer = nil
        AppState.shared.captureEnabled = !paused
        if paused {
            AppLogger.capture.info("capture paused")
            return
        }

        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + .seconds(1), repeating: .seconds(interval))
        t.setEventHandler { [weak self] in
            Task { await self?.tick() }
        }
        t.resume()
        timer = t
        AppLogger.capture.info("capture timer scheduled every \(interval)s")
    }

    private func tick() async {
        if screenLocked || currentCGSessionLocked() {
            // 锁屏期间完全不采集（也省 CPU、Tier-1 配额、磁盘）
            return
        }
        let s = await MainActor.run { SettingsStore.shared.settings }
        let auth = await MainActor.run { AppState.shared.screenRecordingAuthorized }
        if !auth {
            await PermissionsService.shared.refresh()
        }
        do {
            let frames = try await ScreenCapturer.shared.captureAllDisplays(
                maxLongEdge: s.capture.maxLongEdge,
                jpegQuality: s.capture.jpegQuality
            )
            for f in frames {
                await Tier1Pipeline.shared.ingest(frame: f)
            }
            await refreshFailedCount()
        } catch {
            DebugFile.write("tick capture failed: \(error.localizedDescription)")
            AppLogger.capture.error("capture tick failed: \(error.localizedDescription)")
            await MainActor.run { AppState.shared.lastError = "采集失败：\(error.localizedDescription)" }
        }
    }

    private func refreshFailedCount() async {
        let f = (try? FrameRepository.failedCount()) ?? 0
        let rate = computeHourlySuccessRate()
        await MainActor.run {
            AppState.shared.failedAnalysisCount = f
            AppState.shared.hourlySuccessRate = rate
        }
    }

    /// 近 1 小时 done / (done + failed) 比率
    private func computeHourlySuccessRate() -> Double {
        let cutoff = Int64(Date().timeIntervalSince1970 * 1000) - 3_600_000
        do {
            return try Database.shared.pool.read { db in
                let done = try Int.fetchOne(db, sql: "SELECT count(*) FROM frames WHERE captured_at >= ? AND analysis_status='done'", arguments: [cutoff]) ?? 0
                let failed = try Int.fetchOne(db, sql: "SELECT count(*) FROM frames WHERE captured_at >= ? AND analysis_status='failed'", arguments: [cutoff]) ?? 0
                let total = done + failed
                return total == 0 ? 1.0 : Double(done) / Double(total)
            }
        } catch {
            return 1.0
        }
    }

    /// 用 CGSession 同步检查（启动期 / fallback）。要求 OnConsole + ScreenIsLocked。
    private func currentCGSessionLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        let onConsole = (dict["kCGSessionOnConsoleKey"] as? NSNumber)?.boolValue ?? false
        let locked = (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
        return onConsole && locked
    }
}
