import AppKit
import SwiftUI
import FrameRecCore
import FrameRecUI

@MainActor
final class RecordingToolbar: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private weak var coordinator: AppCoordinator?
    private var repositioning = false

    func show(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        if panel == nil {
            let panel = OverlayPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: RecordingToolbarView(coordinator: coordinator, settings: coordinator.settings))
            self.panel = panel
        }
        placeOutsideSelection()
    }

    func placeOutsideSelection() {
        guard let panel, let coordinator, let selection = coordinator.selection else { return }
        guard coordinator.settings.showsToolbar else { panel.orderOut(nil); return }
        let size = CGSize(width: 475, height: 66)
        let otherScreens = NSScreen.screens.filter { $0.frame != selection.screenFrame }.map(\.visibleFrame)
        guard let frame = RegionGeometry.toolbarFrame(size: size, region: selection.rect,
                        preferredScreen: selection.visibleFrame, otherScreens: otherScreens) else {
            panel.orderOut(nil)
            return
        }
        repositioning = true
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        repositioning = false
    }

    func windowDidMove(_ notification: Notification) {
        guard !repositioning, let panel, let selection = coordinator?.selection else { return }
        if panel.frame.intersects(selection.rect.insetBy(dx: -6, dy: -6)) { placeOutsideSelection() }
    }

    func close() { panel?.close(); panel = nil }
}

struct RecordingToolbarView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.secondary).help("拖动控制条")
            if coordinator.phase == .selecting {
                Picker("格式", selection: $settings.format) {
                    ForEach(MovieFormat.allCases, id: \.self) { Text($0.label).tag($0) }
                }.labelsHidden().frame(width: 86)
                Picker("帧率", selection: $settings.frameRate) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) 帧").tag($0) }
                }.labelsHidden().frame(width: 86)
                Toggle(isOn: $settings.showsCursor) { Image(systemName: "cursorarrow") }
                    .toggleStyle(.button).help("录制鼠标指针")
                Button(action: coordinator.startRecording) { Label("开始录屏", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent).tint(FrameRecTheme.accent).foregroundStyle(.black)
                Button(action: coordinator.cancelSelection) { Image(systemName: "xmark") }.buttonStyle(.plain).help("取消框选")
            } else {
                Circle().fill(coordinator.phase == .paused ? Color.orange : Color.red).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(durationLabel(coordinator.elapsed)).monospacedDigit().font(.system(size: 17, weight: .semibold))
                    Text(coordinator.phase.label).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(minWidth: 74, alignment: .leading)
                Button(coordinator.phase == .paused ? "继续录屏" : "暂停录屏", action: coordinator.togglePause)
                    .frame(minWidth: 72)
                Button(action: coordinator.finishRecording) { Label("结束", systemImage: "stop.fill") }
                    .buttonStyle(.borderedProminent).tint(FrameRecTheme.accent).foregroundStyle(.black)
                Button(action: coordinator.requestCancel) { Image(systemName: "xmark") }.buttonStyle(.plain).help("取消本次录屏")
            }
        }
        .controlSize(.regular)
        .tint(FrameRecTheme.accent)
        .padding(.horizontal, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12)))
        .preferredColorScheme(.dark)
        .disabled(coordinator.phase == .starting || coordinator.phase == .finishing)
    }
}
