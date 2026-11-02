import SwiftUI
import AppKit
import ServiceManagement
import FrameRecCore
import FrameRecUI

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ViewState private var loginEnabled = SMAppService.mainApp.status == .enabled
    @ViewState private var loginError: String?

    var body: some View {
        Form {
            Section("录屏权限") {
                LabeledContent("屏幕与系统声音", value: coordinator.hasScreenRecordingPermission ? "已授权" : "当前版本尚未获准")
                if !coordinator.hasScreenRecordingPermission {
                    Button("检查并申请录屏权限…", action: coordinator.requestScreenRecordingPermission)
                }
            }
            Section("录制") {
                Picker("默认格式", selection: $settings.format) {
                    ForEach(MovieFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker("默认帧率", selection: $settings.frameRate) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) 帧 / 秒").tag($0) }
                }
                Toggle("显示鼠标指针", isOn: $settings.showsCursor)
                Toggle("显示录制悬浮条", isOn: $settings.showsToolbar)
                    .onChange(of: settings.showsToolbar) { _, _ in coordinator.applyToolbarPreference() }
                Label("录制电脑内部声音，不使用麦克风", systemImage: "speaker.wave.2")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("历史记录") {
                LabeledContent("自动保存目录") {
                    Button("选择…", action: coordinator.changeDirectory).disabled(coordinator.phase.isBusy)
                }
                Text(settings.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("录屏文件与历史记录保留 30 天，运行期间及下次启动时自动清理。导出的副本长期保留。切换目录后，旧目录的历史仍可查看并按期清理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("全局快捷键") {
                ForEach(ShortcutAction.allCases, id: \.rawValue) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(shortcut: settings.shortcuts[action]!) { shortcut in
                            try coordinator.setShortcut(shortcut, for: action)
                        }
                    }
                }
                Text("点击快捷键后按下新的组合键。录制时按 Esc 可确认放弃。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("启动") {
                Toggle("登录时启动 FrameRec", isOn: Binding(get: { loginEnabled }, set: { enabled in
                    Task {
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try await SMAppService.mainApp.unregister() }
                            loginEnabled = SMAppService.mainApp.status == .enabled
                            loginError = SMAppService.mainApp.status == .requiresApproval
                                ? "请在系统设置中允许 FrameRec 的登录启动。" : nil
                        } catch { loginError = error.localizedDescription }
                    }
                }))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
            }
        }
        .formStyle(.grouped)
        .tint(FrameRecTheme.accent)
        .frame(minWidth: 520, minHeight: 590)
        .onAppear { coordinator.refreshScreenRecordingPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshScreenRecordingPermission()
        }
    }
}

private struct ShortcutRecorder: View {
    let shortcut: Shortcut
    let onChange: (Shortcut) throws -> Void
    @ViewState private var listening = false
    @ViewState private var monitor: Any?
    @ViewState private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Button(listening ? "请按组合键…" : shortcut.label) {
                if listening { stop() } else { start() }
            }.monospaced().frame(minWidth: 110)
            if let message { Text(message).font(.caption2).foregroundStyle(.orange).frame(maxWidth: 230) }
        }
        .onDisappear { stop() }
    }

    private func start() {
        message = nil
        listening = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil }
            guard let next = Shortcut.from(event: event) else {
                message = "组合键需要包含 ⌃、⌥ 或 ⌘。"
                return nil
            }
            do { try onChange(next); stop() }
            catch { message = error.localizedDescription; stop() }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil; listening = false
    }
}
