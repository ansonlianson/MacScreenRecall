import SwiftUI

struct OverviewView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statsGrid
                permissionsCard
                recentSection
                Spacer(minLength: 12)
            }
            .padding(20)
        }
        .navigationTitle("概览")
        .task { await PermissionsService.shared.refresh() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("今日活动").font(.title2).bold()
            Spacer()
            Text(Date.now, format: .dateTime.year().month().day().weekday())
                .foregroundStyle(.secondary)
        }
    }

    private var statsGrid: some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            statCard("帧数", value: "\(appState.todayFrameCount)", systemImage: "photo.stack")
            statCard("待分析", value: "\(appState.pendingAnalysisCount)", systemImage: "hourglass")
            statCard("失败", value: "\(appState.failedAnalysisCount)", systemImage: "exclamationmark.triangle")
            statCard("Tier-1 健康度",
                     value: "\(Int((appState.tier1HealthyRate * 100).rounded()))%",
                     systemImage: "checkmark.seal")
            statCard("Tier-2 健康度",
                     value: "\(Int((appState.tier2HealthyRate * 100).rounded()))%",
                     systemImage: "checkmark.seal")
            statCard("磁盘占用",
                     value: ByteCountFormatter.string(fromByteCount: appState.diskUsageBytes, countStyle: .file),
                     systemImage: "internaldrive")
            statCard("采集间隔",
                     value: "\(settings.settings.capture.intervalSec)s",
                     systemImage: "timer")
        }
    }

    private func statCard(_ title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value).font(.title3).bold().monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var permissionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("权限").font(.headline)
            HStack {
                Image(systemName: appState.screenRecordingAuthorized ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(appState.screenRecordingAuthorized ? .green : .orange)
                Text(appState.screenRecordingAuthorized ? "屏幕录制已授权" : "屏幕录制未授权")
                Spacer()
                if !appState.screenRecordingAuthorized {
                    Button("申请权限") {
                        Task { await PermissionsService.shared.requestScreenCapture() }
                    }
                    Button("打开系统设置") {
                        PermissionsService.shared.openScreenRecordingPreferences()
                    }
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 5 条 summary").font(.headline)
            if appState.recentSummaries.isEmpty {
                Text("尚无数据 — Tier-1 上线后将在此显示").foregroundStyle(.secondary)
            } else {
                ForEach(Array(appState.recentSummaries.prefix(5).enumerated()), id: \.offset) { _, s in
                    Text("• \(s)").font(.callout)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
