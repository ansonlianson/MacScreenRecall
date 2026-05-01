import SwiftUI
import AppKit
import MarkdownUI

struct ReportsView: View {
    @State private var reports: [ReportRow] = []
    @State private var selected: ReportRow?
    @State private var generating = false
    @State private var error: String?
    @State private var refreshTick = 0

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                HStack {
                    Button {
                        Task { await generateNow() }
                    } label: {
                        if generating {
                            ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "doc.badge.plus")
                        }
                        Text(generating ? "生成中…" : "立即生成今日日报")
                    }
                    .disabled(generating)
                    Spacer()
                    Button {
                        load()
                    } label: { Image(systemName: "arrow.clockwise") }
                }
                .padding(.horizontal)
                .padding(.top)

                if reports.isEmpty {
                    ContentUnavailableView("还没有报告",
                                           systemImage: "doc.text",
                                           description: Text("点上方按钮生成今日日报。"))
                } else {
                    List(reports, selection: $selected) { r in
                        ReportListItem(report: r).tag(r as ReportRow?)
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 220, idealWidth: 260)

            ScrollView {
                if let r = selected ?? reports.first {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(formatRange(r))
                                .font(.title3.bold())
                            Spacer()
                            Text("\(r.provider ?? "?") · \(r.model ?? "?")")
                                .font(.caption).foregroundStyle(.secondary)
                            Button {
                                openInFinder(report: r)
                            } label: { Image(systemName: "folder") }
                                .help("在 Finder 中显示 .md 文件")
                        }
                        Divider()
                        Markdown(r.markdown)
                            .markdownTheme(.gitHub)
                            .textSelection(.enabled)
                    }
                    .padding(20)
                    .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    .padding(20)
                } else {
                    Text("选择左侧的一份报告").foregroundStyle(.secondary).padding()
                }
            }
        }
        .navigationTitle("报告")
        .task(id: refreshTick) { load() }
        .onAppear { load() }
        .alert("生成失败", isPresented: .constant(error != nil), actions: {
            Button("好的") { error = nil }
        }, message: {
            Text(error ?? "")
        })
    }

    private func load() {
        reports = (try? ReportsRepository.list()) ?? []
        if selected == nil { selected = reports.first }
    }

    private func generateNow() async {
        generating = true
        defer { generating = false }
        do {
            _ = try await DailyReportService.generate()
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func formatRange(_ r: ReportRow) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "\(r.kind == "daily" ? "日报" : r.kind) — \(f.string(from: Date(timeIntervalSince1970: TimeInterval(r.rangeStart) / 1000)))"
    }

    private func openInFinder(report: ReportRow) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        let day = f.string(from: Date(timeIntervalSince1970: TimeInterval(report.rangeStart) / 1000))
        let url = AppPaths.reportsDir.appendingPathComponent("\(day).md")
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(AppPaths.reportsDir)
        }
    }
}

private struct ReportListItem: View {
    let report: ReportRow
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(dateText).font(.callout)
            Text("生成于 \(generatedText)").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private var dateText: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(report.rangeStart) / 1000))
    }
    private var generatedText: String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(report.generatedAt) / 1000))
    }
}
