import SwiftUI
import AVFoundation
import FrameRecCore
import FrameRecUI

struct HistoryView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ViewState private var search = ""
    private var filtered: [Recording] {
        coordinator.recordings.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("录屏历史").font(.title2.bold())
                    Text("\(coordinator.recordings.count) 段录屏 · 自动保留 30 天").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索录屏", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
                Button { coordinator.beginSelection() } label: { Image(systemName: "plus") }
                    .help("开始新录屏").disabled(coordinator.phase.isBusy)
            }.padding(22)
            Divider()
            if let notice = coordinator.notice {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(notice).font(.caption)
                    Spacer()
                    Button { coordinator.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.foregroundStyle(.orange).padding(12)
            }
            if filtered.isEmpty {
                ContentUnavailableView(search.isEmpty ? "还没有录屏" : "没有匹配的录屏",
                    systemImage: "rectangle.dashed.badge.record", description: Text(search.isEmpty ? "按快捷键框选屏幕，完成后会自动保存在这里。" : "试试其他关键词。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { recording in HistoryRow(recording: recording, coordinator: coordinator) }
                    }.padding(18)
                }
            }
            Divider()
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                Text("需要长期保留的录屏，请导出一份。").font(.caption)
                Spacer()
                Button("设置", action: coordinator.showSettings).buttonStyle(.link)
            }.foregroundStyle(.secondary).padding(14)
        }.frame(minWidth: 700, minHeight: 520)
            .tint(FrameRecTheme.accent)
    }
}

private struct HistoryRow: View {
    let recording: Recording
    @ObservedObject var coordinator: AppCoordinator
    @ViewState private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.7))
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else { Image(systemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                Text(durationLabel(recording.duration)).font(.system(size: 10, weight: .medium, design: .monospaced))
                    .padding(4).background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4)).padding(5)
            }.frame(width: 130, height: 78).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 7) {
                Text(recording.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(recording.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Text("\(recording.width) × \(recording.height) · \(recording.frameRate) 帧 · \(recording.format.label)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { coordinator.openEditor(recording) } label: { Image(systemName: "play.circle").font(.title2) }
                .buttonStyle(.plain).help("预览与剪辑")
            Menu {
                Button("预览与剪辑") { coordinator.openEditor(recording) }
                Button("重命名…") { coordinator.renameRecording(recording) }
                Button("导出副本…") { coordinator.exportRecording(recording) }
                Button("在访达中显示") { if let url = coordinator.fileURL(for: recording) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Divider()
                Button("删除…", role: .destructive) { coordinator.deleteRecording(recording) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { coordinator.openEditor(recording) }
        .task(id: recording.modifiedAt) {
            guard let url = coordinator.fileURL(for: recording) else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 180)
            if let result = try? await generator.image(at: CMTime(seconds: min(0.3, recording.duration / 2), preferredTimescale: 600)) {
                thumbnail = NSImage(cgImage: result.image, size: .zero)
            }
        }
    }
}
