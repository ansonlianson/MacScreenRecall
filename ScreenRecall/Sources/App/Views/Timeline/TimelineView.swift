import SwiftUI
import AppKit

struct TimelineRowItem: Identifiable {
    let id: Int64
    let frame: FrameRow
    let analysis: AnalysisRow?
}

struct TimelineView: View {
    @Environment(AppState.self) private var appState
    @State private var items: [TimelineRowItem] = []
    @State private var loading = false
    @State private var refreshTrigger = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("今日帧数 \(appState.todayFrameCount) ｜待分析 \(appState.pendingAnalysisCount)")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .padding()

            if items.isEmpty {
                ContentUnavailableView(
                    loading ? "加载中…" : "今日还没有采集",
                    systemImage: "calendar.day.timeline.left",
                    description: Text("等下一轮采集，或在菜单栏点 \"开始采集\"。")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(items) { item in
                            TimelineRow(item: item)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .navigationTitle("时间线")
        .task(id: refreshTrigger) { await load() }
        .onAppear { tickRefresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            tickRefresh()
        }
    }

    private func tickRefresh() { refreshTrigger &+= 1 }
    private func refresh() { tickRefresh() }

    private func load() async {
        loading = true
        let rows = (try? FrameRepository.recentForToday(limit: 200)) ?? []
        items = rows.map { TimelineRowItem(id: $0.0.id ?? 0, frame: $0.0, analysis: $0.1) }
        loading = false
    }
}

private struct TimelineRow: View {
    let item: TimelineRowItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
                .frame(width: 160, height: 100)
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(.quaternary, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(timeText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(item.frame.displayLabel ?? item.frame.displayId)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    statusBadge
                }
                if let summary = item.analysis?.summary {
                    Text(summary).font(.callout)
                } else if item.frame.analysisStatus == "skipped" {
                    Text("（与上一帧相似，已去重）").font(.callout).foregroundStyle(.secondary)
                } else if item.frame.analysisStatus == "failed" {
                    Text("分析失败").font(.callout).foregroundStyle(.red)
                } else {
                    Text("待分析…").font(.callout).foregroundStyle(.secondary)
                }
                if let app = item.analysis?.app, !app.isEmpty {
                    Text("应用：\(app) · \(item.analysis?.windowTitle ?? "")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let key = item.analysis?.keyText, !key.isEmpty {
                    Text(key).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var thumbnail: some View {
        if let img = NSImage(contentsOfFile: item.frame.imagePath) {
            return AnyView(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
        } else {
            return AnyView(Color.secondary.opacity(0.1))
        }
    }

    private var timeText: String {
        let d = Date(timeIntervalSince1970: TimeInterval(item.frame.capturedAt) / 1000)
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }

    private var statusBadge: some View {
        let s = item.frame.analysisStatus
        let (label, color): (String, Color) = {
            switch s {
            case "done": return ("done", .green)
            case "pending": return ("pending", .secondary)
            case "analyzing": return ("analyzing", .blue)
            case "failed": return ("failed", .red)
            case "skipped": return ("skipped", .gray)
            default: return (s, .secondary)
            }
        }()
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
    }
}
