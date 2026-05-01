import SwiftUI

struct ModelProfilesEditor: View {
    @Environment(SettingsStore.self) private var store
    @State private var editing: ModelProfile?
    @State private var deleteCandidate: ModelProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(store.settings.profiles.count) 个模型").foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button {
                    editing = ModelProfile(
                        name: "新模型",
                        endpointKind: .openaiCompatible,
                        endpoint: "https://",
                        model: "",
                        kind: .chat
                    )
                } label: { Label("新增模型", systemImage: "plus") }
            }
            ForEach(store.settings.profiles) { p in
                ProfileRow(profile: p) {
                    editing = p
                } onDelete: {
                    deleteCandidate = p
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
            }
        }
        .sheet(item: $editing) { p in
            ModelProfileEditSheet(initial: p) { updated, key in
                store.upsertProfile(updated)
                if let key { KeychainStore.set(forProfileId: updated.id, value: key) }
                editing = nil
            } onCancel: {
                editing = nil
            }
        }
        .alert("删除模型？",
               isPresented: .constant(deleteCandidate != nil),
               presenting: deleteCandidate) { p in
            Button("删除", role: .destructive) {
                store.deleteProfile(id: p.id)
                deleteCandidate = nil
            }
            Button("取消", role: .cancel) { deleteCandidate = nil }
        } message: { p in
            Text("将同时删除 Keychain 中的 API Key，且如果当前 Tier-1/Tier-2/Embedding 指向它会自动解绑。\n\n模型名称：\(p.name)")
        }
    }
}

private struct ProfileRow: View {
    let profile: ModelProfile
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(profile.name).font(.callout)
                    Text(profile.kind.displayName)
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: .capsule)
                }
                Text("\(profile.endpointKind.displayName) · \(profile.model) · \(profile.endpoint)")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { onEdit() } label: { Image(systemName: "pencil") }
                .buttonStyle(.plain)
            Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.red)
        }
        .padding(.vertical, 4)
    }
}

struct ModelProfileEditSheet: View {
    @State private var profile: ModelProfile
    @State private var apiKey: String
    @State private var apiKeyEdited: Bool = false
    let onSave: (ModelProfile, String?) -> Void
    let onCancel: () -> Void

    init(initial: ModelProfile,
         onSave: @escaping (ModelProfile, String?) -> Void,
         onCancel: @escaping () -> Void) {
        self._profile = State(initialValue: initial)
        let stored = KeychainStore.get(forProfileId: initial.id) ?? ""
        self._apiKey = State(initialValue: stored)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("模型").font(.title3.bold())
                Spacer()
                Button { onCancel() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            Form {
                Section {
                    TextField("名称", text: $profile.name).textFieldStyle(.roundedBorder)
                    Picker("端点协议", selection: $profile.endpointKind) {
                        ForEach(EndpointKind.allCases) { k in Text(k.displayName).tag(k) }
                    }
                    Text(profile.endpointKind.hint)
                        .font(.caption2).foregroundStyle(.secondary)
                    TextField("Endpoint / Base URL", text: $profile.endpoint)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    TextField("模型名（如 qwen3.6-plus / bge-m3 / claude-sonnet-4-6）", text: $profile.model)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                    Picker("用途", selection: $profile.kind) {
                        ForEach(ModelKind.allCases) { k in Text(k.displayName).tag(k) }
                    }
                }
                Section("凭据") {
                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) { _, _ in apiKeyEdited = true }
                    Text("存于 macOS Keychain，account = model.\(profile.id.uuidString)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("高级") {
                    Stepper("Max Tokens：\(profile.maxTokens)", value: $profile.maxTokens, in: 256...32_000, step: 256)
                    Stepper("超时：\(profile.timeoutSec)s", value: $profile.timeoutSec, in: 10...600, step: 5)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { onCancel() }
                Button("保存") {
                    onSave(profile, apiKeyEdited ? apiKey : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty
                          || profile.endpoint.trimmingCharacters(in: .whitespaces).isEmpty
                          || profile.model.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }
}
