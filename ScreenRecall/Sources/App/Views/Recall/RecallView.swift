import SwiftUI
import AppKit

/// 「回溯」Tab —— 合并旧的「时间线」与「检索」。
/// 顶部搜索/提问；下方一条时间线展示当日所有 done 帧；
/// - 输入关键字 → 搜索结果
/// - 点提问 → 答案卡 + 引用帧高亮 + 时间线滚到对应位置
struct RecallView: View {
    @Environment(AppState.self) private var appState

    @State private var query: String = ""
    @State private var date: Date = Date()
    @State private var items: [TimelineItem] = []
    @State private var loading = false
    @State private var lastError: String?

    @State private var askResult: AskResult?
    @State private var asking = false

    @State private var refreshTick = 0
    @State private var detailItem: TimelineItem?

    var body: some View {
        VStack(spacing: 0) {
            queryBar
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let r = askResult {
                            AnswerCard(result: r) { frameId in
                                withAnimation { scrollProxy.scrollTo(frameId, anchor: .top) }
                            }
                            .padding(.horizontal)
                            .id("answer")
                        }

                        if items.isEmpty && !loading {
                            ContentUnavailableView(
                                askResult == nil ? "暂无可显示的帧" : "时间窗内无 done 帧",
                                systemImage: "clock.arrow.circlepath",
                                description: Text(askResult == nil
                                    ? "切换日期或等下一次采集；菜单栏可控制采集开关。"
                                    : "调整时间窗或换问题。")
                            )
                            .padding(.top, 60)
                        }

                        ForEach(items) { item in
                            RecallRow(
                                item: item,
                                highlighted: askResult?.hits.contains(where: { $0.id == item.id }) ?? false,
                                onTap: { detailItem = item }
                            )
                            .id(item.id)
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: askResult?.hits.first?.id) { _, newId in
                    if let id = newId {
                        withAnimation { scrollProxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .navigationTitle("回溯")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .onChange(of: date) { _, _ in
                        askResult = nil
                        load()
                    }
            }
        }
        .task(id: refreshTick) { load() }
        .sheet(item: $detailItem) { item in
            FrameDetailSheet(item: item, neighbors: items, onSelect: { detailItem = $0 })
                .frame(minWidth: 900, minHeight: 600)
        }
        .alert("失败", isPresented: .constant(lastError != nil), actions: {
            Button("好的") { lastError = nil }
        }, message: { Text(lastError ?? "") })
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // 只在显示当天且未在搜索/提问态下自动刷新
            if Calendar.current.isDateInToday(date) && askResult == nil && query.isEmpty {
                refreshTick &+= 1
            }
        }
    }

    private var queryBar: some View {
        HStack(spacing: 8) {
            TextField("关键字 / 自然语言提问…", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runAsk() }
            Button("搜索") { runSearch() }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            Button(asking ? "提问中…" : "提问") { runAsk() }
                .buttonStyle(.borderedProminent)
                .disabled(asking || query.trimmingCharacters(in: .whitespaces).isEmpty)
            if askResult != nil || !query.isEmpty {
                Button {
                    askResult = nil; query = ""; load()
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
    }

    private func load() {
        loading = true
        defer { loading = false }
        do {
            if !query.isEmpty && askResult == nil {
                // 关键字搜索模式
                let hits = try Retriever.search(query: query, limit: 200)
                items = hits.map { TimelineItem(frame: $0.frame, analysis: $0.analysis) }
            } else if let r = askResult {
                // 提问模式：取该日的全部帧 + 命中帧高亮
                items = try loadDay(date: date)
                let hitIds = Set(r.hits.compactMap { $0.frame.id })
                items.sort { (a, b) in
                    if hitIds.contains(a.id) != hitIds.contains(b.id) {
                        return hitIds.contains(a.id)
                    }
                    return a.frame.capturedAt > b.frame.capturedAt
                }
            } else {
                items = try loadDay(date: date)
            }
        } catch {
            lastError = "加载失败：\(error.localizedDescription)"
            items = []
        }
    }

    private func loadDay(date: Date) throws -> [TimelineItem] {
        let cal = Calendar.current
        let start = Int64(cal.startOfDay(for: date).timeIntervalSince1970 * 1000)
        let end = Int64(cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: date))!.timeIntervalSince1970 * 1000)
        return try Database.shared.pool.read { db in
            let frames = try FrameRow
                .filter(sql: "captured_at >= ? AND captured_at < ?", arguments: [start, end])
                .order(sql: "captured_at DESC")
                .limit(500)
                .fetchAll(db)
            return frames.compactMap { f -> TimelineItem? in
                guard let id = f.id else { return nil }
                let a: AnalysisRow? = try? AnalysisRow.filter(sql: "frame_id = ?", arguments: [id]).fetchOne(db)
                return TimelineItem(frame: f, analysis: a)
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        askResult = nil
        load()
    }

    private func runAsk() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        asking = true
        Task {
            let r = await AnswerPipeline.ask(q)
            await MainActor.run {
                askResult = r
                asking = false
                load()
            }
        }
    }
}

struct TimelineItem: Identifiable, Hashable {
    var id: Int64 { frame.id ?? 0 }
    let frame: FrameRow
    let analysis: AnalysisRow?
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private struct RecallRow: View {
    let item: TimelineItem
    let highlighted: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbnail
                .frame(width: 240, height: 150)
                .clipShape(.rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(highlighted ? Color.accentColor.opacity(0.8) : Color.secondary.opacity(0.2),
                                lineWidth: highlighted ? 2 : 0.5)
                }
                .shadow(color: highlighted ? .accentColor.opacity(0.3) : .clear, radius: 6)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(timeText).font(.headline).monospacedDigit()
                    if highlighted {
                        Image(systemName: "sparkles").foregroundStyle(.tint).font(.caption)
                    }
                    Spacer()
                    statusBadge
                }
                if let app = item.analysis?.app, !app.isEmpty {
                    Text(app + (item.analysis?.windowTitle.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let summary = item.analysis?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).lineLimit(3)
                } else if item.frame.analysisStatus == "skipped" {
                    Text("（与上一帧相似，已去重）").font(.callout).foregroundStyle(.secondary)
                } else if item.frame.analysisStatus == "failed" {
                    Text("分析失败").font(.callout).foregroundStyle(.red)
                } else {
                    Text("待分析…").font(.callout).foregroundStyle(.secondary)
                }
                if let key = item.analysis?.keyText, !key.isEmpty {
                    Text(key).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            if highlighted {
                Color.accentColor.opacity(0.05)
            }
        }
        .contentShape(.rect(cornerRadius: 10))
        .onTapGesture { onTap() }
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

/// 答案卡：Markdown 答案 + 引用帧缩略图（点击 jumpTo）
private struct AnswerCard: View {
    let result: AskResult
    let onJumpToFrame: (Int64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text(result.usedVision ? "答案（含画面追问）" : "答案").font(.headline)
                Spacer()
                Text("\(result.provider) · \(result.model) · \(result.latencyMs)ms")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if result.degraded {
                Label("当前 Tier-2 模型不支持视觉，已降级为纯 metadata 回答",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(result.answer)
                .textSelection(.enabled)
                .font(.body)
            if !result.hits.isEmpty {
                Divider()
                Text("引用帧（点击跳到对应时间）— 共 \(result.hits.count) 条")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(result.hits.prefix(12)) { h in
                            Button { onJumpToFrame(h.id) } label: {
                                if let img = NSImage(contentsOfFile: h.frame.imagePath) {
                                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                                        .frame(width: 140, height: 88)
                                        .clipShape(.rect(cornerRadius: 8))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 0.5)
                                        }
                                } else {
                                    RoundedRectangle(cornerRadius: 8).fill(.secondary.opacity(0.1))
                                        .frame(width: 140, height: 88)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("时间窗：\(formatTime(result.plan.rangeStartMs)) → \(formatTime(result.plan.rangeEndMs))")
                    Spacer()
                    if !result.diagnostics.keywords.isEmpty {
                        Text("分词：\(result.diagnostics.keywords.joined(separator: " · "))")
                    }
                }
                HStack {
                    Text("FTS 表达式：\(result.diagnostics.ftsExpression.isEmpty ? "(空)" : result.diagnostics.ftsExpression)")
                        .lineLimit(1)
                    Spacer()
                    Text("命中：\(result.hits.count) 帧" + (result.diagnostics.fellBackToWindow ? "（时间窗兜底）" : ""))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .glassEffect(.regular.tint(.blue.opacity(0.05)), in: .rect(cornerRadius: 12))
    }

    private func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}
