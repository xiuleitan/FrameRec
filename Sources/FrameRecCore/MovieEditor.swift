import AVFoundation

public enum MovieEditor {
    public static func composition(source: URL, timeline: EditTimeline) async throws -> AVMutableComposition {
        let asset = AVURLAsset(url: source)
        let sourceTracks = try await asset.load(.tracks)
        let composition = AVMutableComposition()
        for sourceTrack in sourceTracks where sourceTrack.mediaType == .video || sourceTrack.mediaType == .audio {
            guard let track = composition.addMutableTrack(withMediaType: sourceTrack.mediaType,
                                                          preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let sourceExtent = try await sourceTrack.load(.timeRange)
            if sourceTrack.mediaType == .video {
                track.preferredTransform = try await sourceTrack.load(.preferredTransform)
            }
            var cursor = CMTime.zero
            for range in timeline.ranges {
                let requested = CMTimeRange(start: CMTime(seconds: range.start, preferredTimescale: 60_000),
                                            end: CMTime(seconds: range.end, preferredTimescale: 60_000))
                let intersection = requested.intersection(sourceExtent)
                if intersection.isValid && !intersection.isEmpty {
                    let offset = CMTimeSubtract(intersection.start, requested.start)
                    try track.insertTimeRange(intersection, of: sourceTrack, at: CMTimeAdd(cursor, offset))
                }
                cursor = CMTimeAdd(cursor, requested.duration)
            }
        }
        guard composition.tracks(withMediaType: .video).isEmpty == false else {
            throw FrameRecError.message("视频没有可编辑的画面轨道。")
        }
        return composition
    }

    public static func export(composition: AVComposition, to destination: URL, format: MovieFormat,
                              progress: @escaping @Sendable (Float) -> Void = { _ in }) async throws {
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              session.supportedFileTypes.contains(format.fileType) else {
            throw FrameRecError.message("无法导出这种视频格式。")
        }
        session.shouldOptimizeForNetworkUse = true
        let reporter = Task {
            while !Task.isCancelled {
                progress(session.progress)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { reporter.cancel() }
        do {
            try await withTaskCancellationHandler {
                if #available(macOS 15, *) {
                    try await session.export(to: destination, as: format.fileType)
                } else {
                    session.outputURL = destination
                    session.outputFileType = format.fileType
                    await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
                    guard session.status == .completed else {
                        throw session.error ?? FrameRecError.message("剪辑保存失败。")
                    }
                }
            } onCancel: {
                session.cancelExport()
            }
            progress(1)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
