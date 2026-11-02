import Foundation
import Testing
import AVFoundation
import AudioToolbox
@testable import FrameRecCore

final class MediaTests {
    private let directory: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FrameRecMedia-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }

    @Test func testRealVideoAndAudioSurvivePauseAndMiddleDeletion() async throws {
        let source = directory.appendingPathComponent("source.mp4")
        let writer = try MovieWriter(url: source, width: 160, height: 90, frameRate: 30, format: .mp4)
        let colors = try [(UInt8(0), UInt8(0), UInt8(255)), (0, 255, 0), (255, 0, 0)].map { try pixel(b: $0.0, g: $0.1, r: $0.2) }
        for frame in 0..<90 {
            if frame == 30 { writer.pause(at: 1001); writer.resume(at: 1006) }
            let time = 1000 + Double(frame) / 30 + (frame >= 30 ? 5 : 0)
            var accepted = false
            for _ in 0..<200 {
                if writer.appendVideo(colors[frame / 30], sourceTime: time) { accepted = true; break }
                if let error = writer.failure { throw error }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            #expect(accepted, "Encoder did not accept frame \(frame)")
            let sample = try audio(at: time)
            for _ in 0..<200 {
                if writer.appendAudio(sample) { break }
                if let error = writer.failure { throw error }
                try await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        let duration = try await writer.finish(at: 1008)
        #expect(abs(duration - 3) < 0.04)
        let asset = AVURLAsset(url: source)
        let sourceDuration = try await asset.load(.duration).seconds
        #expect(abs(sourceDuration - 3) < 0.08)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(audioTracks.count == 1)
        let audioExtent = try await #require(audioTracks.first).load(.timeRange)
        #expect(audioExtent.duration.seconds > 2.8)

        var timeline = EditTimeline(duration: sourceDuration)
        try timeline.remove(start: 1, end: 2)
        let composition = try await MovieEditor.composition(source: source, timeline: timeline)
        let edited = directory.appendingPathComponent("edited.mp4")
        try await MovieEditor.export(composition: composition, to: edited, format: .mp4)
        let editedAsset = AVURLAsset(url: edited)
        let editedDuration = try await editedAsset.load(.duration).seconds
        #expect(abs(editedDuration - 2) < 0.08)
        let editedAudio = try await editedAsset.loadTracks(withMediaType: .audio)
        #expect(editedAudio.count == 1)
        let editedAudioExtent = try await #require(editedAudio.first).load(.timeRange)
        #expect(abs(editedAudioExtent.duration.seconds - 2) < 0.1)
        let first = try await color(in: editedAsset, at: 0.4)
        let second = try await color(in: editedAsset, at: 1.4)
        #expect(first[0] > 180); #expect(first[2] < 80)
        #expect(second[2] > 180); #expect(second[0] < 80)
        if let fixturePath = ProcessInfo.processInfo.environment["FRAMEREC_FIXTURE_PATH"] {
            let fixture = URL(fileURLWithPath: fixturePath)
            try FileManager.default.createDirectory(at: fixture.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fixture.path) { try FileManager.default.removeItem(at: fixture) }
            try FileManager.default.copyItem(at: edited, to: fixture)
        }
    }

    @Test func testStaticScreenEndsAtPauseNotAtLastChangedFrame() async throws {
        let writer = try MovieWriter(url: directory.appendingPathComponent("still.mov"), width: 160, height: 90, frameRate: 30, format: .mov)
        let buffer = try pixel(b: 0, g: 0, r: 255)
        #expect(writer.appendVideo(buffer, sourceTime: 100))
        writer.pause(at: 102)
        let duration = try await writer.finish(at: 110)
        #expect(abs(duration - 2) < 0.04)
        let actual = try await AVURLAsset(url: writer.url).load(.duration).seconds
        #expect(abs(actual - 2) < 0.08)
    }

    private func pixel(b: UInt8, g: UInt8, r: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32BGRA,
                                         [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard result == kCVReturnSuccess, let buffer else { throw FrameRecError.message("Cannot create fixture frame") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<90 { for x in 0..<160 {
            let offset = y * stride + x * 4
            base[offset] = b; base[offset + 1] = g; base[offset + 2] = r; base[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func audio(at time: Double) throws -> CMSampleBuffer {
        let frames = 1600
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
                      layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw FrameRecError.message("Cannot create fixture audio format") }
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frames * 8,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: frames * 8, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { throw FrameRecError.message("Cannot allocate fixture audio") }
        var samples = [Float](repeating: 0, count: frames * 2)
        for index in 0..<frames {
            let value = Float(sin(2 * .pi * 440 * (time + Double(index) / 48_000))) * 0.1
            samples[index * 2] = value; samples[index * 2 + 1] = value
        }
        status = samples.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: frames * 8)
        }
        guard status == noErr else { throw FrameRecError.message("Cannot populate fixture audio") }
        var result: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames, presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 48_000),
            packetDescriptions: nil, sampleBufferOut: &result)
        guard status == noErr, let result else { throw FrameRecError.message("Cannot create fixture audio sample") }
        return result
    }

    private func color(in asset: AVAsset, at time: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(seconds: time, preferredTimescale: 600))
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(frame.image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
