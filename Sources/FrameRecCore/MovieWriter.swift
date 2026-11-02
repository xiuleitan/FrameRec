import AVFoundation
import CoreVideo

/// Call from one serial queue. Audio and video share one clock and one pause offset.
public final class MovieWriter {
    public let url: URL
    public let frameRate: Int
    public private(set) var timeline = CaptureTimeline()
    public private(set) var failure: Error?
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastFrame: CVPixelBuffer?
    private var lastVideoTime = -Double.infinity
    private var lastAudioTime = -Double.infinity
    private var finished = false

    public init(url: URL, width: Int, height: Int, frameRate: Int, format: MovieFormat) throws {
        self.url = url
        self.frameRate = frameRate
        writer = try AVAssetWriter(outputURL: url, fileType: format.fileType)
        let bitrate = max(4_000_000, min(50_000_000, Int(Double(width * height * frameRate) * 0.15)))
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoMaxKeyFrameIntervalKey: frameRate * 2,
            ],
        ]
        guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
            throw FrameRecError.message("当前区域的尺寸无法编码，请缩小录屏区域后重试。")
        }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ])
        audio.expectsMediaDataInRealTime = true
        guard writer.canAdd(video), writer.canAdd(audio) else {
            throw FrameRecError.message("无法创建视频或声音编码器。")
        }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? FrameRecError.message("无法开始写入视频。") }
        writer.startSession(atSourceTime: .zero)
    }

    public func pause(at time: Double) { timeline.pause(at: time) }
    public func resume(at time: Double) { timeline.resume(at: time) }

    @discardableResult
    public func appendVideo(_ pixelBuffer: CVPixelBuffer, sourceTime: Double) -> Bool {
        guard !finished, timeline.pausedAt == nil, writer.status == .writing else { return false }
        timeline.anchor(at: sourceTime)
        guard let time = timeline.presentationTime(for: sourceTime), time > lastVideoTime,
              video.isReadyForMoreMediaData else { return false }
        let accepted = adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: time, preferredTimescale: 60_000))
        if accepted { lastVideoTime = time; lastFrame = pixelBuffer }
        else { failure = writer.error ?? FrameRecError.message("视频写入失败，可能是磁盘空间不足。") }
        return accepted
    }

    @discardableResult
    public func appendAudio(_ sample: CMSampleBuffer) -> Bool {
        guard !finished, writer.status == .writing, audio.isReadyForMoreMediaData else { return false }
        let sourceTime = sample.presentationTimeStamp.seconds
        guard let time = timeline.presentationTime(for: sourceTime), time > lastAudioTime else { return false }
        var timingCount = 0
        var result = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &timingCount)
        guard result == noErr, timingCount > 0 else { return false }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: timingCount)
        result = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: timingCount,
                                                       arrayToFill: &timings, entriesNeededOut: &timingCount)
        guard result == noErr else { return false }
        let offset = CMTime(seconds: sourceTime - time, preferredTimescale: 60_000)
        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeSubtract(timings[index].presentationTimeStamp, offset)
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(timings[index].decodeTimeStamp, offset)
            }
        }
        var adjusted: CMSampleBuffer?
        result = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
                    sampleTimingEntryCount: timingCount, sampleTimingArray: &timings, sampleBufferOut: &adjusted)
        guard result == noErr, let adjusted else { return false }
        let accepted = audio.append(adjusted)
        if accepted { lastAudioTime = time }
        else { failure = writer.error ?? FrameRecError.message("内部声音写入失败。") }
        return accepted
    }

    public func duration(at time: Double) -> Double { timeline.duration(at: time) }

    /// Finishing may append a held frame so static screens retain their actual duration.
    public func finish(at hostTime: Double) async throws -> Double {
        guard !finished else { throw FrameRecError.message("录制已经结束。") }
        finished = true
        guard let lastFrame, lastVideoTime.isFinite else {
            writer.cancelWriting()
            throw FrameRecError.message("没有录到有效画面，请确认屏幕录制权限后重试。")
        }
        guard writer.status == .writing else {
            throw writer.error ?? failure ?? FrameRecError.message("视频编码已中断，无法完成保存。")
        }
        let duration = max(timeline.duration(at: hostTime), lastVideoTime + 1.0 / Double(frameRate))
        let finalFrameTime = duration - 1.0 / Double(frameRate)
        if finalFrameTime > lastVideoTime + 0.00001 {
            // Allow the encoder to drain before writing the final still frame.
            for _ in 0..<100 where !video.isReadyForMoreMediaData && writer.status == .writing {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            if video.isReadyForMoreMediaData {
                if !adaptor.append(lastFrame, withPresentationTime: CMTime(seconds: finalFrameTime, preferredTimescale: 60_000)) {
                    failure = writer.error ?? FrameRecError.message("无法完成最后一帧。")
                }
            }
        }
        guard writer.status == .writing else {
            throw writer.error ?? failure ?? FrameRecError.message("视频编码已中断，无法完成保存。")
        }
        writer.endSession(atSourceTime: CMTime(seconds: duration, preferredTimescale: 60_000))
        video.markAsFinished()
        audio.markAsFinished()
        await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else {
            throw writer.error ?? failure ?? FrameRecError.message("视频保存失败。")
        }
        if let failure { throw failure }
        return duration
    }

    public func cancel() {
        finished = true
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    }
}
