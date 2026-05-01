import SwiftUI
import AppKit

private enum TodoFilter: String, CaseIterable, Identifiable {
    case open, done, dismissed
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .open: return "待办"
        case .done: return "完成"
        case .dismissed: return "忽略"
        }
    }
}

struct TodosView: View {
    @State private var todos: [TodoRow] = []
    @State private var filter: TodoFilter = .open
    @State private var extracting = false
    @State private var lastInserted: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("", selection: $filter) {
                    ForEach(TodoFilter.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)

                Spacer()

                if let n = lastInserted {
                    Text("刚刚抽取入库 \(n) 条").font(.caption).foregroundStyle(.green)
                }

                Button {
                    Task { await extractNow() }
                } label: {
                    if extracting {
                        ProgressView().scaleEffect(0.6).frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "wand.and.stars")
                    }
                    Text(extracting ? "抽取中…" : "立即抽取")
                }
                .disabled(extracting)
            }
            .padding()

            if todos.isEmpty {
                ContentUnavailableView(
                    filter == .open ? "暂无待办" : "暂无记录",
                    systemImage: "checklist",
                    description: Text("点 \"立即抽取\" 把当日候选生成可执行 TODO。")
                )
            } else {
                List {
                    ForEach(todos) { t in
                        TodoRowView(todo: t,
                                    onToggleDone: { update(id: $0, status: $1) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("TODO")
        .task(id: filter) { load() }
        .onAppear { load() }
        .alert("抽取失败", isPresented: .constant(error != nil), actions: {
            Button("好的") { error = nil }
        }, message: { Text(error ?? "") })
    }

    private func load() {
        todos = (try? TodosRepository.list(status: filter.rawValue)) ?? []
    }

    private func update(id: Int64, status: String) {
        TodosRepository.setStatus(id: id, status: status)
        load()
    }

    private func extractNow() async {
        extracting = true
        defer { extracting = false }
        do {
            let n = try await TodoExtractor.extract()
            lastInserted = n
            load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct TodoRowView: View {
    let todo: TodoRow
    let onToggleDone: (Int64, String) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                if let id = todo.id {
                    onToggleDone(id, todo.status == "done" ? "open" : "done")
                }
            } label: {
                Image(systemName: todo.status == "done" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(todo.status == "done" ? .green : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.text)
                    .strikethrough(todo.status == "done")
                    .foregroundStyle(todo.status == "done" ? .secondary : .primary)
                if let n = todo.notes, !n.isEmpty {
                    Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Text("发现于 \(detectedText)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()

            if todo.status != "dismissed" {
                Button {
                    if let id = todo.id { onToggleDone(id, "dismissed") }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("忽略")
            }
        }
        .padding(.vertical, 4)
    }

    private var detectedText: String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(todo.detectedAt) / 1000))
    }
}
