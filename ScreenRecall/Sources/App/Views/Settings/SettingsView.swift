import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var store = store
        Form {
            Section("采集") {
                LabeledContent("采集间隔") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(store.settings.capture.intervalSec) },
                                set: { store.settings.capture.intervalSec = Int($0) }
                            ),
                            in: 5...600,
                            step: 1
                        )
                        Text("\(store.settings.capture.intervalSec)s")
                            .monospacedDigit()
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("暂停采集", isOn: $store.settings.capture.paused)
                Stepper("保留原图天数：\(store.settings.retention.imagesDays)",
                        value: $store.settings.retention.imagesDays, in: 1...365)
                Stepper("保留分析天数：\(store.settings.retention.analysesDays)",
                        value: $store.settings.retention.analysesDays, in: 1...1095)
            }

            Section("Tier-1 实时分析") {
                providerEditor(for: $store.settings.tier1)
                SecureField("API Key", text: $store.tier1ApiKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Tier-2 衍生能力") {
                providerEditor(for: $store.settings.tier2)
                SecureField("API Key", text: $store.tier2ApiKey)
                    .textFieldStyle(.roundedBorder)
                if !tier2SupportsVision {
                    Label("当前 Tier-2 模型可能不支持视觉，画面细节追问将不可用",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section("日报 / TODO") {
                LabeledContent("自动生成时间") {
                    TextField("HH:MM", text: $store.settings.reports.dailyAt)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                }
                Toggle("精简模式", isOn: $store.settings.reports.concise)
                Picker("TODO 抽取频率", selection: $store.settings.todos.extractMode) {
                    ForEach(TodoExtractMode.allCases) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                Toggle("TODO 二次审核", isOn: $store.settings.todos.secondaryReview)
            }

            Section("可靠性") {
                LabeledContent("失败帧数") {
                    HStack {
                        Text("\(appState.failedAnalysisCount)").monospacedDigit()
                        Spacer()
                        Button("全部重试") {
                            let n = FrameRepository.requeueFailed()
                            AppLogger.tier1.info("requeued \(n) failed frames")
                            Task { await Tier1Pipeline.shared.reconcileWorkers() }
                        }
                        .disabled(appState.failedAnalysisCount == 0)
                    }
                }
                LabeledContent("待分析队列") {
                    Text("\(appState.pendingAnalysisCount) 帧").monospacedDigit().foregroundStyle(.secondary)
                }
            }

            Section("计划任务") {
                ScheduledTasksEditor()
            }

            Section("启动 / 系统") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { store.settings.ui.launchAtLogin },
                    set: { newValue in
                        let (ok, err) = LaunchAgentService.setLaunchAtLogin(newValue)
                        if ok {
                            store.settings.ui.launchAtLogin = newValue
                        } else if let err = err {
                            appState.lastError = "登录启动项失败：\(err)"
                        }
                    }
                ))
                LabeledContent("当前状态") {
                    Text(launchStatusText).foregroundStyle(.secondary).font(.caption)
                }
            }

            Section("自检") {
                SelfCheckPanel()
            }

            Section("权限") {
                LabeledContent("屏幕录制") {
                    HStack {
                        Image(systemName: appState.screenRecordingAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.screenRecordingAuthorized ? .green : .red)
                        Text(appState.screenRecordingAuthorized ? "已授权" : "未授权")
                        Spacer()
                        Button("申请") {
                            Task { await PermissionsService.shared.requestScreenCapture() }
                        }
                        Button("打开系统设置") {
                            PermissionsService.shared.openScreenRecordingPreferences()
                        }
                    }
                }
                LabeledContent("通知") {
                    HStack {
                        Image(systemName: appState.notificationAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(appState.notificationAuthorized ? .green : .secondary)
                        Text(appState.notificationAuthorized ? "已授权" : "未授权")
                        Spacer()
                        Button("申请") {
                            Task { await PermissionsService.shared.requestNotifications() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
    }

    @ViewBuilder
    private func providerEditor(for binding: Binding<ProviderSettings>) -> some View {
        Picker("Provider", selection: binding.provider) {
            ForEach(ProviderKind.allCases) { p in
                Text(p.displayName).tag(p)
            }
        }
        TextField("Endpoint", text: binding.endpoint)
            .textFieldStyle(.roundedBorder)
        TextField("模型", text: binding.model)
            .textFieldStyle(.roundedBorder)
        Stepper("超时：\(binding.wrappedValue.timeoutSec)s",
                value: binding.timeoutSec, in: 10...600)
        Stepper("并发：\(binding.wrappedValue.concurrency)",
                value: binding.concurrency, in: 1...4)
        LabeledContent("温度") {
            HStack {
                Slider(value: binding.temperature, in: 0...1, step: 0.05)
                Text(String(format: "%.2f", binding.wrappedValue.temperature))
                    .monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }

    private var launchStatusText: String {
        switch LaunchAgentService.status {
        case .notRegistered: return "未注册"
        case .enabled: return "已启用（登录时自动启动）"
        case .requiresApproval: return "需用户在系统设置批准"
        case .notFound: return "未找到 .app（请用 Finder 启动一次）"
        @unknown default: return "未知"
        }
    }

    private var tier2SupportsVision: Bool {
        let m = store.settings.tier2.model.lowercased()
        return ["vl", "vision", "opus", "sonnet", "gpt-4o", "gpt-4.1", "claude",
                "qwen3", "qwen-3", "qwen2.5", "qwen2-5"]
            .contains(where: m.contains)
    }
}
