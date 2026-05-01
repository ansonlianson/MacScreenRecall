import SwiftUI

struct ScheduledTasksEditor: View {
    @State private var tasks: [ScheduledTaskRow] = []
    @State private var editing: ScheduledTaskRow?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(tasks.count) 条任务").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button {
                    editing = ScheduledTaskRow(
                        id: nil, name: "新任务", cron: "manual",
                        prompt: "总结最近 8 小时的工作重点", outputKind: "report",
                        enabled: 1, lastRunAt: nil, lastStatus: nil
                    )
                } label: { Label("新建", systemImage: "plus") }
            }
            ForEach(tasks) { t in
                HStack {
                    Toggle("", isOn: Binding(
                        get: { t.isEnabled },
                        set: { newVal in
                            var n = t; n.enabled = newVal ? 1 : 0
                            _ = try? ScheduledTasksRepository.upsert(n); load()
                        }
                    ))
                    .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.callout)
                        Text("\(t.cron) → \(outputLabel(t.outputKind))").font(.caption2).foregroundStyle(.secondary)
                        if let s = t.lastStatus, let at = t.lastRunAt {
                            Text("上次：\(formatTime(at))｜\(s)").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("立即运行") {
                        Task {
                            do { _ = try await ScheduledTaskRunner.run(t); load() }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    Button {
                        editing = t
                    } label: { Image(systemName: "pencil") }
                    Button(role: .destructive) {
                        if let id = t.id { ScheduledTasksRepository.delete(id: id); load() }
                    } label: { Image(systemName: "trash") }
                }
                Divider()
            }
        }
        .onAppear { load() }
        .sheet(item: $editing) { t in
            ScheduledTaskEditSheet(task: t) { updated in
                _ = try? ScheduledTasksRepository.upsert(updated)
                editing = nil
                load()
            } onCancel: {
                editing = nil
            }
        }
        .alert("失败", isPresented: .constant(error != nil), actions: {
            Button("好的") { error = nil }
        }, message: { Text(error ?? "") })
    }

    private func load() {
        tasks = (try? ScheduledTasksRepository.list()) ?? []
    }

    private func outputLabel(_ s: String) -> String {
        switch s {
        case "todo": return "TODO"
        case "notification": return "通知"
        default: return "报告"
        }
    }

    private func formatTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
    }
}

private struct ScheduledTaskEditSheet: View {
    @State var task: ScheduledTaskRow
    let onSave: (ScheduledTaskRow) -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("基础") {
                TextField("名称", text: $task.name).textFieldStyle(.roundedBorder)
                Toggle("启用", isOn: Binding(
                    get: { task.isEnabled },
                    set: { task.enabled = $0 ? 1 : 0 }
                ))
            }
            Section("调度") {
                TextField("Cron", text: $task.cron).textFieldStyle(.roundedBorder)
                Text("语法：\"manual\" / \"daily HH:MM\" / \"weekly D HH:MM\"（D=1..7，1=周一）/ \"hourly:N\"")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section("输出") {
                Picker("输出类型", selection: $task.outputKind) {
                    Text("报告").tag("report")
                    Text("TODO").tag("todo")
                    Text("通知").tag("notification")
                }
            }
            Section("Prompt") {
                TextEditor(text: $task.prompt).frame(minHeight: 120).font(.body)
            }
            HStack {
                Button("取消", role: .cancel) { onCancel() }
                Spacer()
                Button("保存") { onSave(task) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .padding()
    }
}
