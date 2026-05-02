import SwiftUI
import AppKit
import MarkdownUI

/// 「回溯」Tab —— Rewind 风格：
///   主区域：当前选中帧的大图 + meta + 答案叠层
///   底部：水平时间轴 strip（缩略图带），← → 导航，命中帧高亮
///   顶部：搜索框 / 提问 + 日期选择
struct RecallView: View {
    @Environment(AppState.self) private var appState

    @State private var query: String = ""
    @State private var date: Date = Date()
    @State private var items: [TimelineItem] = []
    @State private var selectedId: Int64?
    @State private var loading = false
    @State private var lastError: String?

    @State private var askResult: AskResult?
    @State private var asking = false
    @State private var searchHitIds: Set<Int64> = []   // 当前命中集合（搜索 / 提问 共用）
    @State private var refreshTick = 0
    @State private var showAnswer = true               // 答案卡折叠

    var body: some View {
        VStack(spacing: 0) {
            queryBar
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)

            // 主区域：大图 + 答案叠层
            ZStack(alignment: .topLeading) {
                mainViewer
                if let r = askResult, showAnswer {
                    answerOverlay(r)
                        .padding(12)
                        .frame(maxWidth: 480)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background.tertiary)

            Divider()

            // 底部：水平时间线
            timelineStrip
                .frame(height: 130)
                .background(.background)
        }
        .navigationTitle("回溯")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DatePicker("", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                    .onChange(of: date) { _, _ in
                        clearAsk()
                        load(autoSelect: true)
                    }
            }
        }
        .task(id: refreshTick) { load(autoSelect: selectedId == nil) }
        .onAppear { load(autoSelect: true) }
        .alert("失败", isPresented: .constant(lastError != nil), actions: {
            Button("好的") { lastError = nil }
        }, message: { Text(lastError ?? "") })
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            // 只有当前显示当天 + 没在搜索/提问 + 未手动选过帧 时自动刷新
            if Calendar.current.isDateInToday(date) && askResult == nil && query.isEmpty && selectedId == items.first?.id {
                refreshTick &+= 1
            }
        }
        .onKeyPress(.leftArrow) { navigate(-1); return .handled }
        .onKeyPress(.rightArrow) { navigate(1); return .handled }
    }

    // MARK: - Top bar

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
                    clearAsk()
                    query = ""
                    load(autoSelect: true)
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("清空")
            }
        }
    }

    // MARK: - Main viewer (large image)

    private var mainViewer: some View {
        Group {
            if let item = currentItem {
                VStack(spacing: 0) {
                    if let img = NSImage(contentsOfFile: item.frame.imagePath) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView("图像缺失", systemImage: "photo.badge.exclamationmark",
                                               description: Text(item.frame.imagePath))
                    }
                    metaBar(item)
                }
            } else {
                ContentUnavailableView(
                    loading ? "加载中…" : "今日无可显示的帧",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(loading ? "" : "切换日期或等下一次采集")
                )
            }
        }
    }

    private func metaBar(_ item: TimelineItem) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(timeText(item.frame.capturedAt)).font(.title2).bold().monospacedDigit()
                    if let app = item.analysis?.app, !app.isEmpty {
                        Text("·").foregroundStyle(.secondary)
                        Text(app).foregroundStyle(.secondary)
                    }
                    Spacer()
                    statusBadge(item.frame.analysisStatus)
                    Text("\(currentIndex + 1) / \(items.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if let summary = item.analysis?.summary, !summary.isEmpty {
                    Text(summary).font(.callout).lineLimit(3)
                }
                if let key = item.analysis?.keyText, !key.isEmpty {
                    Text(key).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
    }

    // MARK: - Answer overlay

    private func answerOverlay(_ r: AskResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.blue)
                Text(r.usedVision ? "答案（含画面追问）" : "答案").font(.headline)
                Spacer()
                Button {
                    showAnswer.toggle()
                } label: {
                    Image(systemName: "chevron.up")
                        .rotationEffect(showAnswer ? .zero : .degrees(180))
                }
                .buttonStyle(.plain)
            }
            if r.degraded {
                Label("Tier-2 不支持视觉，已降级", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ScrollView {
                Markdown(r.answer)
                    .markdownTheme(.gitHub)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack {
                Text("窗：\(formatTime(r.plan.rangeStartMs))→\(formatTime(r.plan.rangeEndMs))")
                Spacer()
                Text("FTS \(r.diagnostics.ftsHitCount)·Emb \(r.diagnostics.embeddingHitCount)·命中 \(r.hits.count)")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .glassEffect(.regular.tint(.blue.opacity(0.05)), in: .rect(cornerRadius: 12))
    }

    // MARK: - Bottom timeline strip

    private var timelineStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(items) { item in
                        ThumbCell(
                            item: item,
                            isSelected: item.id == selectedId,
                            isHit: searchHitIds.contains(item.id),
                            onTap: { selectedId = item.id }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: selectedId) { _, newId in
                if let id = newId {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            .onChange(of: items.count) { _, _ in
                if let id = selectedId { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    // MARK: - data

    private var currentItem: TimelineItem? {
        items.first { $0.id == selectedId } ?? items.first
    }

    private var currentIndex: Int {
        guard let id = selectedId, let i = items.firstIndex(where: { $0.id == id }) else { return 0 }
        return i
    }

    private func navigate(_ delta: Int) {
        guard let id = selectedId, let i = items.firstIndex(where: { $0.id == id }) else { return }
        let next = max(0, min(items.count - 1, i + delta))
        selectedId = items[next].id
    }

    private func load(autoSelect: Bool) {
        loading = true
        defer { loading = false }
        do {
            if !query.isEmpty && askResult == nil {
                let hits = try Retriever.search(query: query, limit: 200)
                let hitIds = Set(hits.compactMap { $0.frame.id })
                searchHitIds = hitIds
                items = try loadDay(date: date)
            } else {
                searchHitIds = Set(askResult?.hits.compactMap { $0.frame.id } ?? [])
                items = try loadDay(date: date)
            }
            // items 是按 captured_at DESC 排（最新在前）
            if autoSelect || selectedId == nil || !items.contains(where: { $0.id == selectedId }) {
                // 优先跳到第一个命中；没命中则第一帧
                if let first = items.first(where: { searchHitIds.contains($0.id) }) {
                    selectedId = first.id
                } else {
                    selectedId = items.first?.id
                }
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
                .filter(sql: "captured_at >= ? AND captured_at < ? AND analysis_status != 'skipped'",
                        arguments: [start, end])
                .order(sql: "captured_at DESC")
                .limit(800)
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
        clearAsk()
        load(autoSelect: true)
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
                showAnswer = true
                load(autoSelect: true)
            }
        }
    }

    private func clearAsk() {
        askResult = nil
        searchHitIds = []
    }

    // MARK: - format helpers

    private func timeText(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }

    private func statusBadge(_ s: String) -> some View {
        let (label, color): (String, Color) = {
            switch s {
            case "done": return ("done", .green)
            case "pending": return ("pending", .secondary)
            case "analyzing": return ("analyzing", .blue)
            case "failed": return ("failed", .red)
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

struct TimelineItem: Identifiable, Hashable {
    var id: Int64 { frame.id ?? 0 }
    let frame: FrameRow
    let analysis: AnalysisRow?
    static func == (l: Self, r: Self) -> Bool { l.id == r.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

private struct ThumbCell: View {
    let item: TimelineItem
    let isSelected: Bool
    let isHit: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            thumb
                .frame(width: 160, height: 96)
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor, lineWidth: isSelected ? 2.5 : (isHit ? 2 : 0.5))
                }
                .shadow(color: isHit ? .accentColor.opacity(0.4) : .clear, radius: 4)
            Text(timeText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(.rect)
        .onTapGesture { onTap() }
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if isHit { return .accentColor.opacity(0.7) }
        return .secondary.opacity(0.2)
    }

    private var thumb: some View {
        if let img = NSImage(contentsOfFile: item.frame.imagePath) {
            return AnyView(Image(nsImage: img).resizable().aspectRatio(contentMode: .fill))
        } else {
            return AnyView(Color.secondary.opacity(0.1))
        }
    }

    private var timeText: String {
        let d = Date(timeIntervalSince1970: TimeInterval(item.frame.capturedAt) / 1000)
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
