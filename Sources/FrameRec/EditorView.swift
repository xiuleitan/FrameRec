import SwiftUI
import AVKit
import FrameRecCore
import FrameRecUI

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                MoviePlayerView(player: model.player)
                if model.isPreparing { ProgressView().controlSize(.large).tint(.white) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Button { model.step(-1) } label: { Image(systemName: "backward.frame") }.help("上一帧")
                    Button(action: model.togglePlayback) {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 22)
                    }.keyboardShortcut(.space, modifiers: [])
                    Button { model.step(1) } label: { Image(systemName: "forward.frame") }.help("下一帧")
                    Text("\(durationLabel(model.position, precise: true)) / \(durationLabel(model.duration, precise: true))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.recording.width) × \(model.recording.height) · \(model.recording.frameRate) 帧")
                        .font(.caption).foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
                CutTimelineView(model: model).frame(height: 76)
                HStack(spacing: 12) {
                    if model.selectionEnd > model.selectionStart {
                        Text("待删除 \(durationLabel(model.selectionStart, precise: true)) — \(durationLabel(model.selectionEnd, precise: true))")
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.orange)
                    } else {
                        Text("点击定位 · 拖动选出待删除区间 · 两端手柄可微调")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.hasChanges || model.isPreparing).keyboardShortcut("z", modifiers: .command).help("撤销")
                    Button("删除选中", action: model.deleteSelection)
                        .disabled(!model.canDelete).keyboardShortcut(.delete, modifiers: [])
                }
                Divider()
                HStack {
                    Text(model.hasChanges ? "剪辑尚未保存" : "已自动保存 · 历史保留 30 天")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("导出副本…") { coordinator.exportRecording(model.recording) }
                        .disabled(model.hasChanges || model.isSaving)
                        .help(model.hasChanges ? "请先保存剪辑，再导出" : "长期保留，不参与历史清理")
                    Button("保存剪辑") { model.save() }
                        .buttonStyle(.borderedProminent).tint(FrameRecTheme.accent).foregroundStyle(.black)
                        .disabled(!model.hasChanges || model.isSaving || model.isPreparing)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }.padding(20).background(Color(nsColor: .windowBackgroundColor))
                .disabled(model.isSaving)
        }
        .overlay {
            if model.isSaving {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 14) {
                        ProgressView(value: Double(model.progress)).frame(width: 230)
                        Text("正在保存剪辑 \(Int(model.progress * 100))%…").font(.callout)
                        Text("完成后更新历史视频").font(.caption).foregroundStyle(.secondary)
                    }.padding(30).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .preferredColorScheme(.dark)
        .tint(FrameRecTheme.accent)
        .alert("无法完成操作", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("确定") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}

private struct MoviePlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct CutTimelineView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let duration = max(0.001, model.duration)
            let left = model.selectionStart / duration * width
            let right = model.selectionEnd / duration * width
            VStack(spacing: 5) {
                HStack {
                    ForEach(0..<5) { tick in
                        if tick > 0 { Spacer(minLength: 0) }
                        Text(durationLabel(duration * Double(tick) / 4, precise: duration < 10)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07))
                    Canvas { context, size in
                        for tick in 0...40 {
                            let x = size.width * Double(tick) / 40
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: tick % 5 == 0 ? 10 : 18))
                            path.addLine(to: CGPoint(x: x, y: size.height - 10))
                            context.stroke(path, with: .color(.white.opacity(tick % 5 == 0 ? 0.17 : 0.06)), lineWidth: 1)
                        }
                    }.allowsHitTesting(false)
                    if right > left {
                        Rectangle().fill(.orange.opacity(0.27)).frame(width: max(1, right - left)).offset(x: left)
                            .overlay(alignment: .topLeading) { EmptyView() }.allowsHitTesting(false)
                    }
                    Rectangle().fill(FrameRecTheme.accent).frame(width: 2).offset(x: min(width - 2, model.position / duration * width))
                        .allowsHitTesting(false)
                }
                .frame(height: 48).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let initial = model.snapped(value.startLocation.x / width * duration)
                    let current = model.snapped(value.location.x / width * duration)
                    if abs(value.translation.width) >= 3 {
                        model.selectionStart = min(initial, current)
                        model.selectionEnd = max(initial, current)
                    }
                    model.player.pause()
                    model.seek(to: current)
                }.onEnded { value in
                    if abs(value.translation.width) < 3 {
                        model.selectionStart = 0; model.selectionEnd = 0
                    }
                })
                .overlay(alignment: .topLeading) {
                    if right > left {
                        selectionHandle(at: left, width: width, duration: duration, isStart: true)
                        selectionHandle(at: right, width: width, duration: duration, isStart: false)
                    }
                }
                .coordinateSpace(name: "cutTimeline")
            }
        }.disabled(model.isPreparing || model.isSaving || model.duration <= 0)
    }

    private func selectionHandle(at x: Double, width: Double, duration: Double, isStart: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3).fill(.orange).frame(width: 8, height: 48)
            .overlay(Capsule().fill(.black.opacity(0.5)).frame(width: 2, height: 16))
            .offset(x: max(0, min(width - 8, x - 4)))
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("cutTimeline"))
                .onChanged { value in
                    let time = model.snapped(value.location.x / width * duration)
                    if isStart { model.selectionStart = max(0, min(time, model.selectionEnd - 1.0 / Double(model.recording.frameRate))) }
                    else { model.selectionEnd = min(duration, max(time, model.selectionStart + 1.0 / Double(model.recording.frameRate))) }
                    model.player.pause(); model.seek(to: time)
                })
    }
}
