import AppKit
import ScreenCaptureKit
import AVFoundation
import FrameRecCore

final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.framerec.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var writer: MovieWriter?
    private var accepting = false
    private var reportingFailure = false
    var onFailure: (@Sendable (Error) -> Void)?

    static var hostTime: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    func start(selection: CaptureSelection, url: URL, format: MovieFormat,
               frameRate: Int, showsCursor: Bool) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw FrameRecError.message("所选显示器已断开，请重新框选。")
        }
        // Excluding the process also covers windows created after capture starts.
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = RegionGeometry.captureRect(region: selection.rect, screen: selection.screenFrame)
        config.width = selection.width
        config.height = selection.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = showsCursor
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        if #available(macOS 15, *) { config.captureMicrophone = false }
        let movieWriter = try MovieWriter(url: url, width: selection.width, height: selection.height,
                                           frameRate: frameRate, format: format)
        queue.sync { self.writer = movieWriter; self.accepting = true; self.reportingFailure = false }
        let capture = SCStream(filter: filter, configuration: config, delegate: self)
        stream = capture
        do {
            try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try capture.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
            try await capture.startCapture()
        }
        catch {
            queue.sync { accepting = false; writer?.cancel(); writer = nil }
            stream = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func pause() { queue.sync { writer?.pause(at: Self.hostTime) } }
    func resume() { queue.sync { writer?.resume(at: Self.hostTime) } }
    var elapsed: Double { queue.sync { writer?.duration(at: Self.hostTime) ?? 0 } }

    func finish() async throws -> Double {
        let end = Self.hostTime
        let movieWriter = queue.sync { () -> MovieWriter? in accepting = false; return writer }
        if let stream { try? await stream.stopCapture() }
        self.stream = nil
        guard let movieWriter else { throw FrameRecError.message("当前没有正在录制的视频。") }
        defer { queue.sync { writer = nil } }
        return try await movieWriter.finish(at: end)
    }

    func cancel() async {
        queue.sync { accepting = false; writer?.cancel() }
        if let stream { try? await stream.stopCapture() }
        stream = nil
        queue.sync { writer = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, sampleBuffer.isValid, let writer else { return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let buffer = sampleBuffer.imageBuffer else { return }
            writer.appendVideo(buffer, sourceTime: sampleBuffer.presentationTimeStamp.seconds)
        case .audio: writer.appendAudio(sampleBuffer)
        default: break
        }
        if let failure = writer.failure, !reportingFailure {
            reportingFailure = true
            onFailure?(failure)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in
            guard let self, self.accepting, !self.reportingFailure else { return }
            self.reportingFailure = true
            self.onFailure?(error)
        }
    }
}
