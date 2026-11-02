import AppKit
import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers
import FrameRecCore
import FrameRecUI

enum RecordingPhase: Equatable {
    case idle, selecting, starting, recording, paused, finishing
    var label: String {
        switch self {
        case .idle: return "准备就绪"
        case .selecting: return "选择录屏区域"
        case .starting: return "正在开始…"
        case .recording: return "正在录屏"
        case .paused: return "已暂停"
        case .finishing: return "正在保存…"
        }
    }
    var isCapturing: Bool { self == .recording || self == .paused }
    var isBusy: Bool { self != .idle && self != .selecting }
}

@MainActor
final class AppCoordinator: NSObject, ObservableObject, NSMenuDelegate {
    let settings = AppSettings()
    @Published private(set) var phase: RecordingPhase = .idle
    @Published private(set) var selection: CaptureSelection?
    @Published private(set) var elapsed = 0.0
    @Published private(set) var recordings: [Recording] = []
    @Published var notice: String?
    @Published private(set) var hasScreenRecordingPermission = false
    private var stores: [HistoryStore] = []
    private var activeStore: HistoryStore?
    private let engine = CaptureEngine()
    private let selector = RegionSelector()
    private let border = RegionBorder()
    private let toolbar = RecordingToolbar()
    private let hotKeys = HotKeyManager()
    private let screenPermission = ScreenRecordingPermission()
    private let applicationVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    private var statusItem: NSStatusItem!
    private var ticker: Timer?
    private var cleaner: Timer?
    private var libraryWindow: NSWindowController?
    private var settingsWindow: NSWindowController?
    private var editors: [UUID: EditorWindowController] = [:]
    private var confirmingCancel = false
    private var displayObserver: NSObjectProtocol?
    private var toast: NSPanel?
    private var toastDismiss: DispatchWorkItem?
    private struct Session {
        let id: UUID
        let stagingURL: URL
        let selection: CaptureSelection
        let format: MovieFormat
        let frameRate: Int
        let createdAt: Date
        let store: HistoryStore
    }
    private var session: Session?

    func launch() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatus()
        hotKeys.onAction = { [weak self] id in
            guard let self, !self.confirmingCancel else { return }
            switch id {
            case 1: self.beginSelection()
            case 2: self.togglePause()
            case 3: self.finishRecording()
            case 99:
                if self.phase == .selecting { self.cancelSelection() }
                else { self.requestCancel() }
            default: break
            }
        }
        for action in ShortcutAction.allCases {
            do { try hotKeys.register(settings.shortcuts[action]!, id: action.rawValue) }
            catch { notice = error.localizedDescription }
        }
        selector.onSelection = { [weak self] selection in
            guard let self, self.phase == .selecting else { return }
            self.selection = selection
            self.toolbar.show(coordinator: self)
            self.updateStatus()
        }
        selector.onCancel = { [weak self] in self?.cancelSelection() }
        selector.onClear = { [weak self] in
            guard let self, self.phase == .selecting else { return }
            self.selection = nil
            self.toolbar.close()
            self.updateStatus()
        }
        engine.onFailure = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.phase.isCapturing else { return }
                self.notice = "录屏中断：\(error.localizedDescription)"
                self.finishRecording()
            }
        }
        loadLibraries()
        refreshScreenRecordingPermission()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.phase.isCapturing { self.elapsed = self.engine.elapsed; self.updateStatus() }
            }
        }
        if let ticker { RunLoop.main.add(ticker, forMode: .common) }
        cleaner = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanHistory() }
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        // On first launch, explain the shortcut without requesting capture permission yet.
        if !UserDefaults.standard.bool(forKey: "hasLaunched") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showToast("FrameRec 已就绪", detail: "按 \(settings.shortcuts[.select]!.label) 框选录屏区域", recording: nil)
        }
    }

    private func loadLibraries() {
        let paths = UserDefaults.standard.stringArray(forKey: "knownDirectories") ?? []
        var unique = Set<URL>()
        for url in [settings.directory] + paths.map({ URL(fileURLWithPath: $0) }) {
            let normalized = url.standardizedFileURL
            guard unique.insert(normalized).inserted else { continue }
            // Do not recreate unavailable old external volumes.
            guard normalized == settings.directory.standardizedFileURL || FileManager.default.fileExists(atPath: normalized.path) else { continue }
            do {
                let store = try HistoryStore(directory: normalized)
                stores.append(store)
                if normalized == settings.directory.standardizedFileURL { activeStore = store }
            } catch { notice = "无法打开历史目录：\(error.localizedDescription)" }
        }
        rememberLibraries()
        cleanHistory()
    }

    private func rememberLibraries() {
        let previous = UserDefaults.standard.stringArray(forKey: "knownDirectories") ?? []
        UserDefaults.standard.set(Array(Set(previous + stores.map { $0.directory.path })).sorted(), forKey: "knownDirectories")
    }

    private func refreshRecords() { recordings = stores.flatMap(\.recordings).sorted { $0.createdAt > $1.createdAt } }

    func cleanHistory() {
        for store in stores {
            do {
                try store.cleanExpired(excluding: Set(editors.keys))
                try store.removeMissingEntries()
            } catch { notice = "历史清理未完成：\(error.localizedDescription)" }
        }
        refreshRecords()
    }

    func fileURL(for recording: Recording) -> URL? { try? store(for: recording)?.fileURL(for: recording) }
    private func store(for recording: Recording) -> HistoryStore? {
        stores.first { $0.recordings.contains(where: { $0.id == recording.id }) }
    }

    @objc func beginSelection() {
        guard phase == .idle || phase == .selecting else { return }
        if phase == .selecting { cancelSelection() }
        guard activeStore != nil else { showSettings(); showError("请先设置一个可写入的历史保存目录。"); return }
        statusItem.menu?.cancelTracking()
        guard ensureScreenRecordingPermission() else { return }
        closeToast()
        selection = nil
        phase = .selecting
        elapsed = 0
        hotKeys.setEscapeEnabled(true)
        updateStatus()
        // Opening a status menu leaves AppKit in menu tracking mode. Present the
        // mouse-capturing panels only after the menu action has returned.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase == .selecting else { return }
            self.selector.show()
        }
    }

    @objc func cancelSelection() {
        guard phase == .selecting else { return }
        selector.close(); toolbar.close()
        selection = nil; phase = .idle
        hotKeys.setEscapeEnabled(false)
        updateStatus()
    }

    @objc func startRecording() {
        guard phase == .selecting, let selection, let store = activeStore else { return }
        if !screenPermission.isAuthorized {
            cancelSelection()
            _ = ensureScreenRecordingPermission()
            return
        }
        let id = UUID()
        let session = Session(id: id, stagingURL: store.stagingDirectory.appendingPathComponent("\(id.uuidString).\(settings.format.rawValue)"),
                              selection: selection, format: settings.format, frameRate: settings.frameRate, createdAt: Date(), store: store)
        self.session = session
        phase = .starting
        selector.close()
        border.show(selection.rect, paused: false)
        toolbar.show(coordinator: self)
        updateStatus()
        let cursor = settings.showsCursor
        Task {
            do {
                try await engine.start(selection: selection, url: session.stagingURL, format: session.format,
                                       frameRate: session.frameRate, showsCursor: cursor)
                phase = .recording
                toolbar.show(coordinator: self)
                updateStatus()
            } catch {
                resetCapture()
                showError("无法开始录屏", detail: error.localizedDescription)
            }
        }
    }

    func refreshScreenRecordingPermission() {
        hasScreenRecordingPermission = screenPermission.isAuthorized
    }

    func requestScreenRecordingPermission() {
        if ensureScreenRecordingPermission() {
            showToast("录屏权限已就绪", detail: "现在可以框选屏幕开始录制", recording: nil)
        }
    }

    private func ensureScreenRecordingPermission() -> Bool {
        refreshScreenRecordingPermission()
        if hasScreenRecordingPermission { return true }
        NSApp.activate(ignoringOtherApps: true)
        hasScreenRecordingPermission = screenPermission.requestAccess()
        guard !hasScreenRecordingPermission else { return true }
        let alert = NSAlert()
        alert.messageText = "当前版本的录屏授权尚未生效"
        alert.informativeText = "请在系统设置 → 隐私与安全性 → 录屏与系统录音中允许 FrameRec。\n\n如果开关已经开启却仍出现本提示，可能保留了旧版本的授权记录。请选中旧的 FrameRec 项并点“－”移除，再点“＋”添加下面这一份应用，然后完全退出并重新打开 FrameRec。\n\n当前版本：\(applicationVersion)\n当前应用：\(Bundle.main.bundleURL.path)\n\n麦克风不会被使用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "在访达中显示当前应用")
        alert.addButton(withTitle: "稍后")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        } else if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
        return false
    }

    @objc func togglePause() {
        if phase == .recording { engine.pause(); phase = .paused }
        else if phase == .paused { engine.resume(); phase = .recording }
        else { return }
        elapsed = engine.elapsed
        if let selection { border.show(selection.rect, paused: phase == .paused) }
        updateStatus()
    }

    @objc func finishRecording() {
        guard phase.isCapturing else { return }
        Task { _ = await completeRecording() }
    }

    @discardableResult
    private func completeRecording() async -> Bool {
        guard phase.isCapturing, let session else { return false }
        phase = .finishing
        hotKeys.setEscapeEnabled(false)
        updateStatus()
        do {
            let duration = try await engine.finish()
            let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let name = "录屏 \(formatter.string(from: session.createdAt)) \(session.id.uuidString.prefix(6))"
            let record = Recording(id: session.id, fileName: name + "." + session.format.rawValue,
                createdAt: session.createdAt, duration: duration, width: session.selection.width,
                height: session.selection.height, frameRate: session.frameRate, format: session.format, title: name)
            try session.store.add(record, moving: session.stagingURL)
            refreshRecords()
            resetCapture()
            showToast("录屏已保存 · \(durationLabel(duration))", detail: "点击预览或剪辑 · 历史保存 30 天", recording: record)
            return true
        } catch {
            resetCapture()
            let exists = FileManager.default.fileExists(atPath: session.stagingURL.path)
            showError("录屏保存未完成", detail: error.localizedDescription + (exists ? "\n\n临时文件保留在：\n\(session.stagingURL.path)" : ""))
            return false
        }
    }

    @objc func requestCancel() {
        guard phase.isCapturing, !confirmingCancel else { return }
        confirmingCancel = true
        let wasRecording = phase == .recording
        if wasRecording { togglePause() }
        hotKeys.setEscapeEnabled(false)
        let alert = NSAlert()
        alert.messageText = "放弃本次录屏？"
        alert.informativeText = "放弃后，本次录制的内容会被删除。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: wasRecording ? "继续录屏" : "保留录屏")
        alert.addButton(withTitle: "放弃录屏")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalentModifierMask = []
        NSApp.activate(ignoringOtherApps: true)
        let escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { NSApp.stopModal(withCode: .alertFirstButtonReturn); return nil }
            return event
        }
        let result = alert.runModal()
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        confirmingCancel = false
        guard phase.isCapturing else { return }
        if result == .alertSecondButtonReturn {
            phase = .finishing
            let temporary = session?.stagingURL
            updateStatus()
            Task {
                await engine.cancel()
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                resetCapture()
            }
        } else {
            hotKeys.setEscapeEnabled(true)
            if wasRecording { togglePause() }
        }
    }

    private func resetCapture() {
        selector.close(); toolbar.close(); border.close()
        session = nil; selection = nil; phase = .idle; elapsed = 0
        hotKeys.setEscapeEnabled(false)
        updateStatus()
    }

    private func screensChanged() {
        guard let selection else { return }
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == selection.displayID
        }
        if phase == .selecting {
            beginSelection()
        } else if phase.isCapturing {
            if screen == nil || screen?.frame != selection.screenFrame || screen?.backingScaleFactor != selection.scale {
                notice = "显示器配置发生变化，正在结束录屏。"
                finishRecording()
            } else { toolbar.placeOutsideSelection() }
        }
    }

    func changeDirectory() {
        guard !phase.isBusy else { showError("请先结束本次录屏，再修改保存目录。"); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = settings.directory
        panel.prompt = "设为历史目录"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let store = try stores.first(where: { $0.directory == url.standardizedFileURL }) ?? HistoryStore(directory: url)
            let probe = store.stagingDirectory.appendingPathComponent("write-test-\(UUID().uuidString)")
            try Data().write(to: probe); try FileManager.default.removeItem(at: probe)
            if !stores.contains(where: { $0 === store }) { stores.append(store) }
            activeStore = store
            settings.setDirectory(url)
            rememberLibraries(); cleanHistory()
        } catch { showError("无法使用这个目录", detail: error.localizedDescription) }
    }

    func setShortcut(_ shortcut: Shortcut, for action: ShortcutAction) throws {
        guard !settings.shortcuts.contains(where: { $0.key != action && $0.value.keyCode == shortcut.keyCode && $0.value.modifiers == shortcut.modifiers }) else {
            throw FrameRecError.message("这个快捷键已用于另一项操作。")
        }
        let old = settings.shortcuts[action]!
        do {
            try hotKeys.register(shortcut, id: action.rawValue)
            settings.setShortcut(shortcut, for: action)
        } catch {
            try? hotKeys.register(old, id: action.rawValue)
            throw error
        }
    }

    func applyToolbarPreference() {
        if phase != .idle { toolbar.show(coordinator: self) }
    }

    func openEditor(_ recording: Recording) {
        if let editor = editors[recording.id] { editor.showWindow(nil); editor.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        guard let url = fileURL(for: recording) else { showError("找不到这个视频文件。"); return }
        closeToast()
        let controller = EditorWindowController(recording: recording, sourceURL: url, coordinator: self)
        controller.onClose = { [weak self] in self?.editors.removeValue(forKey: recording.id) }
        editors[recording.id] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func commitEdit(recording: Recording, temporary: URL) throws {
        guard let store = store(for: recording) else { throw FrameRecError.message("历史记录已不存在。") }
        // A history rename while its editor is open must survive the subsequent save.
        var updated = store.recordings.first(where: { $0.id == recording.id }) ?? recording
        updated.duration = recording.duration
        updated.modifiedAt = recording.modifiedAt
        try store.replace(updated, with: temporary)
        refreshRecords()
    }

    func stagingURL(for recording: Recording) throws -> URL {
        guard let store = store(for: recording) else { throw FrameRecError.message("历史目录已不可用。") }
        return store.stagingDirectory.appendingPathComponent("edit-\(UUID().uuidString).\(recording.format.rawValue)")
    }

    func exportRecording(_ recording: Recording) {
        guard let source = fileURL(for: recording) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [recording.format == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = recording.fileName
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        if stores.contains(where: { store in store.recordings.contains { (try? store.fileURL(for: $0).standardizedFileURL) == destination.standardizedFileURL } }) {
            showError("请选择历史文件以外的位置或文件名。", detail: "导出的副本将长期保留，不参与 30 天清理。")
            return
        }
        do {
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".framerec-export-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { showError("导出失败", detail: error.localizedDescription) }
    }

    func deleteRecording(_ recording: Recording) {
        guard editors[recording.id] == nil else { showError("请先关闭这个视频的预览窗口。"); return }
        let alert = NSAlert()
        alert.messageText = "删除这条录屏？"
        alert.informativeText = recording.title
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try store(for: recording)?.delete(recording); refreshRecords() }
        catch { showError("删除失败", detail: error.localizedDescription) }
    }

    func renameRecording(_ recording: Recording) {
        let alert = NSAlert(); alert.messageText = "重命名录屏"
        let field = NSTextField(string: recording.title)
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var updated = recording; updated.title = title
        do { try store(for: recording)?.update(updated); refreshRecords() }
        catch { showError("重命名失败", detail: error.localizedDescription) }
    }

    @objc func showLibrary() {
        cleanHistory()
        if libraryWindow == nil {
            libraryWindow = makeWindow(title: "FrameRec · 历史记录", size: CGSize(width: 720, height: 560),
                                       view: HistoryView(coordinator: self))
        }
        libraryWindow?.showWindow(nil); libraryWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(title: "FrameRec · 设置", size: CGSize(width: 540, height: 590),
                                        view: SettingsView(coordinator: self, settings: settings))
        }
        settingsWindow?.showWindow(nil); settingsWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow<V: View>(title: String, size: CGSize, view: V) -> NSWindowController {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.minSize = size; window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.center()
        return NSWindowController(window: window)
    }

    func showError(_ message: String, detail: String = "") {
        let alert = NSAlert()
        alert.messageText = message; alert.informativeText = detail; alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func updateStatus() {
        guard let button = statusItem?.button else { return }
        let symbol = phase == .paused ? "pause.circle.fill" : phase.isCapturing ? "record.circle" : "viewfinder"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FrameRec")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = phase.isCapturing ? " " + durationLabel(elapsed) : (phase == .finishing ? " 保存中" : "")
        button.toolTip = "FrameRec · \(phase.label)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector? = nil, enabled: Bool = true) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled
            menu.addItem(item); return item
        }
        menu.autoenablesItems = false
        _ = add("FrameRec \(applicationVersion) · \(phase.label)", enabled: false)
        switch phase {
        case .idle: _ = add("开始区域录屏…    \(settings.shortcuts[.select]!.label)", #selector(beginSelection))
        case .selecting:
            _ = add("开始录制当前选区", #selector(startRecording), enabled: selection != nil)
            if let selection { _ = add("\(selection.width) × \(selection.height)", enabled: false) }
            let formatItem = add("格式与帧率")
            let formats = NSMenu()
            for format in MovieFormat.allCases {
                let item = NSMenuItem(title: format.label, action: #selector(selectFormat(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = format.rawValue
                item.state = settings.format == format ? .on : .off; formats.addItem(item)
            }
            formats.addItem(.separator())
            for fps in [24, 30, 60] {
                let item = NSMenuItem(title: "\(fps) 帧", action: #selector(selectFrameRate(_:)), keyEquivalent: "")
                item.target = self; item.tag = fps; item.state = settings.frameRate == fps ? .on : .off; formats.addItem(item)
            }
            formatItem.submenu = formats
            _ = add("取消框选", #selector(cancelSelection))
        case .recording, .paused:
            _ = add("\(phase == .paused ? "继续录屏" : "暂停录屏")    \(settings.shortcuts[.pause]!.label)", #selector(togglePause))
            _ = add("结束并保存    \(settings.shortcuts[.stop]!.label)", #selector(finishRecording))
            _ = add("放弃本次录屏…    Esc", #selector(requestCancel))
        case .starting, .finishing: break
        }
        if phase == .selecting || phase.isCapturing {
            _ = add(settings.showsToolbar ? "隐藏悬浮条" : "显示悬浮条", #selector(toggleToolbar))
        }
        menu.addItem(.separator())
        for recording in recordings.prefix(5) {
            let item = add("\(recording.title)  ·  \(durationLabel(recording.duration))", #selector(openRecent(_:)))
            item.representedObject = recording.id.uuidString
        }
        _ = add("全部历史记录…", #selector(showLibrary))
        _ = add("设置…", #selector(showSettings))
        menu.addItem(.separator())
        _ = add("退出 FrameRec", #selector(quit))
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let recording = recordings.first(where: { $0.id.uuidString == id }) else { return }
        openEditor(recording)
    }
    @objc private func selectFormat(_ sender: NSMenuItem) { if let value = sender.representedObject as? String, let format = MovieFormat(rawValue: value) { settings.format = format } }
    @objc private func selectFrameRate(_ sender: NSMenuItem) { settings.frameRate = sender.tag }
    @objc private func toggleToolbar() { settings.showsToolbar.toggle(); applyToolbarPreference() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func showToast(_ title: String, detail: String, recording: Recording?) {
        closeToast()
        guard let screen = NSScreen.main else { return }
        let frame = CGRect(x: screen.visibleFrame.maxX - 350, y: screen.visibleFrame.maxY - 105, width: 330, height: 82)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: Button(action: { [weak self] in
            if let recording { self?.openEditor(recording) } else { self?.closeToast() }
        }) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(FrameRecTheme.accent).font(.title2)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(16).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain).preferredColorScheme(.dark))
        panel.orderFrontRegardless()
        toast = panel
        let dismiss = DispatchWorkItem { [weak self] in self?.closeToast() }
        toastDismiss = dismiss
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: dismiss)
    }

    private func closeToast() { toastDismiss?.cancel(); toastDismiss = nil; toast?.close(); toast = nil }

    func shouldTerminate() -> NSApplication.TerminateReply {
        if phase == .starting || phase == .finishing || editors.values.contains(where: { $0.model.isSaving }) {
            showError("正在处理视频，请稍后退出。")
            return .terminateCancel
        }
        if editors.values.contains(where: { $0.model.hasChanges }) {
            let alert = NSAlert(); alert.messageText = "有尚未保存的剪辑，仍要退出吗？"
            alert.informativeText = "原始录屏已保存，未保存的剪辑将被放弃。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "退出")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        if phase.isCapturing {
            let alert = NSAlert(); alert.messageText = "退出前如何处理本次录屏？"
            alert.addButton(withTitle: "保存并退出"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃并退出")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return .terminateCancel }
            Task {
                if response == .alertFirstButtonReturn {
                    let saved = await completeRecording()
                    NSApp.reply(toApplicationShouldTerminate: saved)
                } else {
                    let temporary = session?.stagingURL
                    await engine.cancel()
                    if let temporary { try? FileManager.default.removeItem(at: temporary) }
                    NSApp.reply(toApplicationShouldTerminate: true)
                }
            }
            return .terminateLater
        }
        return .terminateNow
    }

    func shutdown() {
        hotKeys.invalidate(); ticker?.invalidate(); cleaner?.invalidate()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
    }
}
