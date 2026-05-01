import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: appState.captureEnabled ? "eye.fill" : "eye.slash.fill")
                    .foregroundStyle(appState.captureEnabled ? Color.accentColor : Color.secondary)
                Text("Screen Recall").font(.headline)
                Spacer()
            }

            Divider()

            statRow("今日帧数", value: "\(appState.todayFrameCount)")
            statRow("待分析队列", value: "\(appState.pendingAnalysisCount)")
            statRow("Tier-1", value: settings.tier1Profile()?.name ?? "未配置")
            statRow("最近分析",
                    value: appState.lastAnalyzedAt.map { Self.timeFormatter.string(from: $0) } ?? "—")
            statRow("权限",
                    value: appState.screenRecordingAuthorized ? "已授权" : "未授权",
                    valueColor: appState.screenRecordingAuthorized ? .green : .red)

            if let err = appState.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider()

            Button(appState.captureEnabled ? "暂停采集" : "开始采集") {
                appState.captureEnabled.toggle()
                settings.settings.capture.paused = !appState.captureEnabled
            }

            Button("打开主窗口") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }

            Button("立即生成日报") {
                Task {
                    do { _ = try await DailyReportService.generate() }
                    catch { AppState.shared.lastError = "日报失败：\(error.localizedDescription)" }
                }
            }
            Button("立即抽取 TODO") {
                Task {
                    do { _ = try await TodoExtractor.extract() }
                    catch { AppState.shared.lastError = "TODO 抽取失败：\(error.localizedDescription)" }
                }
            }

            Divider()

            Button("退出") { NSApp.terminate(nil) }
        }
        .padding(14)
        .frame(width: 280)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private func statRow(_ label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(valueColor).monospacedDigit()
        }
        .font(.callout)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
}
