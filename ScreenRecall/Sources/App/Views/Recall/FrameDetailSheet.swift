import SwiftUI
import AppKit

/// 单帧详情：原图全屏 + analysis JSON 全展开 + 邻近帧导航
struct FrameDetailSheet: View {
    let item: TimelineItem
    let neighbors: [TimelineItem]   // 用于 ‹ › 导航
    let onSelect: (TimelineItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { navigate(-1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(currentIndex == nil || currentIndex == 0)
                Button { navigate(1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(currentIndex == nil || currentIndex == (neighbors.count - 1))
                Spacer()
                Text(headerText).font(.headline)
                Spacer()
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.frame.imagePath)])
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()

            HSplitView {
                ScrollView([.horizontal, .vertical]) {
                    if let img = NSImage(contentsOfFile: item.frame.imagePath) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(minWidth: 600, minHeight: 400)
                    } else {
                        Text("图像缺失：\(item.frame.imagePath)").foregroundStyle(.red).padding()
                    }
                }
                .frame(minWidth: 500)

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        section("基础") {
                            kv("时间", timeText)
                            kv("显示器", item.frame.displayLabel ?? item.frame.displayId)
                            kv("尺寸", "\(item.frame.width ?? 0) × \(item.frame.height ?? 0)")
                            kv("大小", ByteCountFormatter.string(fromByteCount: Int64(item.frame.bytes ?? 0), countStyle: .file))
                            kv("状态", item.frame.analysisStatus)
                            if let dedup = item.frame.dedupOfId {
                                kv("dedup_of", "#\(dedup)")
                            }
                        }
                        if let a = item.analysis {
                            section("分析") {
                                kv("provider", a.provider)
                                kv("model", a.model)
                                kv("latency", "\(a.latencyMs ?? 0) ms")
                                kv("tokens in / out", "\(a.tokensIn ?? 0) / \(a.tokensOut ?? 0)")
                                kv("activity_type", a.activityType ?? "—")
                                kv("app", a.app ?? "—")
                                kv("window_title", a.windowTitle ?? "—")
                                kv("url", a.url ?? "—")
                            }
                            if let s = a.summary, !s.isEmpty {
                                section("summary") {
                                    Text(s).textSelection(.enabled).font(.callout)
                                }
                            }
                            if let k = a.keyText, !k.isEmpty {
                                section("key_text") {
                                    Text(k).textSelection(.enabled).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            jsonBlock("tags", a.tagsJson)
                            jsonBlock("entities", a.entitiesJson)
                            jsonBlock("visible_numbers", a.numbersJson)
                            jsonBlock("todo_candidates", a.todoCandidatesJson)
                            if let raw = a.rawResponse, !raw.isEmpty {
                                section("raw_response") {
                                    Text(raw).textSelection(.enabled).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                }
                .frame(minWidth: 380)
            }
        }
    }

    private var currentIndex: Int? {
        neighbors.firstIndex(of: item)
    }

    private func navigate(_ delta: Int) {
        guard let i = currentIndex else { return }
        let target = i + delta
        guard (0..<neighbors.count).contains(target) else { return }
        onSelect(neighbors[target])
    }

    private var headerText: String {
        "Frame #\(item.frame.id ?? 0) · \(timeText)"
    }

    private var timeText: String {
        let d = Date(timeIntervalSince1970: TimeInterval(item.frame.capturedAt) / 1000)
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(v).font(.caption).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func jsonBlock(_ title: String, _ json: String?) -> some View {
        if let json, !json.isEmpty, json != "[]" {
            section(title) {
                Text(prettyJSON(json) ?? json)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func prettyJSON(_ s: String) -> String? {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
              let str = String(data: pretty, encoding: .utf8) else { return nil }
        return str
    }
}
