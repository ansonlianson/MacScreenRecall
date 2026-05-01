import SwiftUI
import AppKit

struct SearchView: View {
    @State private var query: String = ""
    @State private var keywordHits: [RetrievedHit] = []
    @State private var askResult: AskResult?
    @State private var isAsking = false
    @State private var lastError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("关键字搜索 / 自然语言提问…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runSearch() }
                Button("搜索") { runSearch() }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
                Button(isAsking ? "提问中…" : "提问") { runAsk() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(isAsking || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let r = askResult {
                        AnswerCard(result: r)
                    }
                    if let err = lastError {
                        Text(err).foregroundStyle(.red).padding(.horizontal)
                    }
                    if !keywordHits.isEmpty {
                        Text("匹配 \(keywordHits.count) 帧").font(.headline).padding(.horizontal)
                        ForEach(keywordHits) { hit in
                            HitRow(hit: hit)
                            Divider().padding(.horizontal)
                        }
                    } else if askResult == nil {
                        ContentUnavailableView(
                            "试一下",
                            systemImage: "magnifyingglass",
                            description: Text("用 ⌘+Enter 关键字搜索；用 Enter 自然语言提问。")
                        )
                        .padding(.top, 40)
                    }
                }
                .padding(.bottom)
            }
        }
        .navigationTitle("检索")
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        lastError = nil
        askResult = nil
        do {
            keywordHits = try Retriever.search(query: q, limit: 50)
        } catch {
            keywordHits = []
            lastError = "检索失败：\(error.localizedDescription)"
        }
    }

    private func runAsk() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        lastError = nil
        keywordHits = []
        askResult = nil
        isAsking = true
        Task {
            let result = await AnswerPipeline.ask(q)
            await MainActor.run {
                askResult = result
                isAsking = false
            }
        }
    }
}

private struct AnswerCard: View {
    let result: AskResult

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
                Text("引用帧（\(min(8, result.hits.count))/\(result.hits.count)）").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(result.hits.prefix(8)) { h in
                            ThumbCell(hit: h)
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
        .padding(.horizontal)
    }

    private func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

private struct HitRow: View {
    let hit: RetrievedHit
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbCell(hit: hit)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(timeText).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Text(hit.analysis.app ?? "").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(hit.analysis.summary ?? "").font(.callout)
                if let key = hit.analysis.keyText, !key.isEmpty {
                    Text(key).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
    }
    private var timeText: String {
        let d = Date(timeIntervalSince1970: TimeInterval(hit.frame.capturedAt) / 1000)
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }
}

private struct ThumbCell: View {
    let hit: RetrievedHit
    var body: some View {
        if let img = NSImage(contentsOfFile: hit.frame.imagePath) {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 140, height: 88)
                .clipShape(.rect(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(.quaternary, lineWidth: 0.5) }
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.secondary.opacity(0.1))
                .frame(width: 140, height: 88)
        }
    }
}
