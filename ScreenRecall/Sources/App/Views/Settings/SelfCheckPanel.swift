import SwiftUI
import AppKit

struct SelfCheckPanel: View {
    @State private var result: SelfCheckResult?
    @State private var checking = false

    var body: some View {
        innerBody
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 10))
    }

    private var innerBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let r = result {
                    Label("成功率（近 1h）：\(Int((r.lastHourSuccessRate * 100).rounded()))%（\(r.lastHourDone)/\(r.lastHourTotal)）",
                          systemImage: "waveform.path.ecg")
                        .foregroundStyle(r.lastHourSuccessRate >= 0.5 ? .green : .red)
                } else {
                    Text("尚未自检").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await runCheck() }
                } label: {
                    if checking {
                        ProgressView().scaleEffect(0.6)
                    } else {
                        Image(systemName: "stethoscope")
                    }
                    Text(checking ? "检查中…" : "运行自检")
                }
                .disabled(checking)
            }
            if let r = result {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                    grid("屏幕录制权限", ok: r.screenRecording, suffix: nil)
                    grid("通知权限", ok: r.notification, suffix: nil)
                    grid("数据库", ok: r.dbReachable, suffix: nil)
                    grid("Tier-1 (\(r.tier1Provider))", ok: r.tier1Reachable ?? false,
                         suffix: r.tier1Latency.map { "\($0)ms" })
                    grid("Tier-2 (\(r.tier2Provider))", ok: r.tier2Reachable ?? false,
                         suffix: r.tier2Latency.map { "\($0)ms" })
                    GridRow {
                        Text("磁盘可用").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: r.diskFreeBytes, countStyle: .file))
                    }
                    GridRow {
                        Text("frames 占用").foregroundStyle(.secondary)
                        Text(ByteCountFormatter.string(fromByteCount: r.framesDirBytes, countStyle: .file))
                    }
                }
                .font(.caption)
            }
            HStack {
                Button("打开数据目录") {
                    NSWorkspace.shared.open(AppPaths.supportDir)
                }
                Button("打开日志目录") {
                    NSWorkspace.shared.open(AppPaths.logsDir)
                }
            }
        }
    }

    @ViewBuilder
    private func grid(_ title: String, ok: Bool, suffix: String?) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            HStack {
                Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(ok ? .green : .red)
                if let s = suffix {
                    Text(s).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    private func runCheck() async {
        checking = true
        defer { checking = false }
        result = await SelfCheckService.run()
    }
}
