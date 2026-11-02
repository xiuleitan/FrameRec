import AppKit
import SwiftUI
import AVFoundation
import FrameRecCore

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var recording: Recording
    @Published private(set) var timeline = EditTimeline(duration: 0)
    @Published private(set) var undoStack: [EditTimeline] = []
    @Published private(set) var position = 0.0
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = true
    @Published private(set) var isSaving = false
    @Published private(set) var progress: Float = 0
    @Published var selectionStart = 0.0
    @Published var selectionEnd = 0.0
    @Published var errorMessage: String?
    let player = AVPlayer()
    let sourceURL: URL
    private weak var coordinator: AppCoordinator?
    private var observer: Any?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    var hasChanges: Bool { !undoStack.isEmpty }
    var duration: Double { timeline.duration }
    var canDelete: Bool {
        !isPreparing && !isSaving && selectionEnd - selectionStart >= 0.5 / Double(recording.frameRate)
            && duration - (selectionEnd - selectionStart) >= 1.0 / Double(recording.frameRate) - 0.0001
    }

    init(recording: Recording, sourceURL: URL, coordinator: AppCoordinator) {
        self.recording = recording
        self.sourceURL = sourceURL
        self.coordinator = coordinator
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.isPlaying = self.player.rate > 0
            }
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let asset = AVURLAsset(url: sourceURL)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0 else { throw FrameRecError.message("这个视频没有有效的时长。") }
                try Task.checkCancellation()
                timeline = EditTimeline(duration: duration)
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                isPreparing = false
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription; isPreparing = false }
            }
        }
    }

    func seek(to time: Double) {
        let target = min(max(0, time), max(0, duration - 0.001))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 60_000), toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
    }

    func togglePlayback() {
        guard !isPreparing, !isSaving else { return }
        if player.rate > 0 { player.pause(); isPlaying = false }
        else {
            if position >= duration - 0.05 { seek(to: 0) }
            player.play(); isPlaying = true
        }
    }

    func step(_ frames: Int) {
        player.pause(); isPlaying = false
        seek(to: position + Double(frames) / Double(recording.frameRate))
    }

    func snapped(_ time: Double) -> Double {
        min(duration, max(0, (time * Double(recording.frameRate)).rounded() / Double(recording.frameRate)))
    }

    func deleteSelection() {
        guard canDelete else { return }
        var next = timeline
        do { try next.remove(start: selectionStart, end: selectionEnd, minimumRemaining: 1.0 / Double(recording.frameRate)) }
        catch { errorMessage = error.localizedDescription; return }
        let previous = timeline
        let target = selectionStart
        rebuild(next, seekTo: target) { self.undoStack.append(previous) }
    }

    func undo() {
        guard let previous = undoStack.last, !isPreparing, !isSaving else { return }
        rebuild(previous, seekTo: position) { self.undoStack.removeLast() }
    }

    private func rebuild(_ next: EditTimeline, seekTo time: Double, commit: @escaping () -> Void) {
        player.pause(); isPlaying = false; isPreparing = true
        Task {
            do {
                let composition = try await MovieEditor.composition(source: sourceURL, timeline: next)
                commit()
                timeline = next
                player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
                selectionStart = 0; selectionEnd = 0
                seek(to: time)
            } catch { errorMessage = error.localizedDescription }
            isPreparing = false
        }
    }

    func save(completion: (() -> Void)? = nil) {
        guard hasChanges, !isSaving, !isPreparing, let coordinator else { return }
        player.pause(); isPlaying = false; isSaving = true; progress = 0
        saveTask = Task {
            var temporary: URL?
            var exported = false
            do {
                let output = try coordinator.stagingURL(for: recording)
                temporary = output
                let composition = try await MovieEditor.composition(source: sourceURL, timeline: timeline)
                try await MovieEditor.export(composition: composition, to: output, format: recording.format) { progress in
                    Task { @MainActor in self.progress = progress }
                }
                exported = true
                var updated = recording
                updated.duration = duration; updated.modifiedAt = Date()
                try coordinator.commitEdit(recording: updated, temporary: output)
                recording = updated
                timeline = EditTimeline(duration: updated.duration)
                undoStack.removeAll()
                selectionStart = 0; selectionEnd = 0
                player.replaceCurrentItem(with: AVPlayerItem(url: sourceURL))
                seek(to: 0)
                isSaving = false
                completion?()
            } catch {
                if let temporary, !exported { try? FileManager.default.removeItem(at: temporary) }
                errorMessage = error.localizedDescription
                    + (exported ? "\n\n已生成的剪辑结果保留在：\n\(temporary?.path ?? "")" : "")
                isSaving = false
            }
        }
    }

    func close() {
        loadTask?.cancel()
        player.pause()
        if let observer { player.removeTimeObserver(observer); self.observer = nil }
        player.replaceCurrentItem(with: nil)
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorModel
    var onClose: (() -> Void)?
    private var allowClose = false
    private weak var coordinator: AppCoordinator?

    init(recording: Recording, sourceURL: URL, coordinator: AppCoordinator) {
        model = EditorModel(recording: recording, sourceURL: sourceURL, coordinator: coordinator)
        self.coordinator = coordinator
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = recording.title
        window.minSize = CGSize(width: 760, height: 570)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorView(model: model, coordinator: coordinator))
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isSaving || model.isPreparing {
            coordinator?.showError("正在处理视频，请稍后关闭。")
            return false
        }
        guard model.hasChanges, !allowClose else { return true }
        let alert = NSAlert()
        alert.messageText = "保存这次剪辑吗？"
        alert.informativeText = "未保存的修改会被放弃，原始录屏会保留。"
        alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃修改")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save { [weak self] in self?.allowClose = true; self?.window?.performClose(nil) }
            return false
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) { model.close(); onClose?() }
}
