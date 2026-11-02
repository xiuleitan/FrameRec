import Foundation
import Testing
@testable import FrameRecCore

final class TimelineTests {
    @Test func testRepeatedDeletionUsesEditedCoordinates() throws {
        var timeline = EditTimeline(duration: 20)
        try timeline.remove(start: 5, end: 10)
        try timeline.remove(start: 3, end: 8)
        #expect(timeline.ranges == [SourceRange(start: 0, end: 3), SourceRange(start: 13, end: 20)])
        #expect(abs(timeline.duration - 10) < 0.00001)
        #expect(abs(timeline.sourceTime(at: 3) - 13) < 0.00001)
        #expect(abs(timeline.sourceTime(at: 9) - 19) < 0.00001)
    }

    @Test func testHeadTailDeletionAndInvalidSelection() throws {
        var timeline = EditTimeline(duration: 10)
        try timeline.remove(start: 0, end: 2)
        try timeline.remove(start: 6, end: 8)
        #expect(timeline.ranges == [SourceRange(start: 2, end: 8)])
        let before = timeline
        #expect(throws: FrameRecError.self) { try timeline.remove(start: 0, end: 6) }
        #expect(throws: FrameRecError.self) { try timeline.remove(start: -.infinity, end: 1) }
        #expect(throws: FrameRecError.self) { try timeline.remove(start: 4, end: 3) }
        #expect(timeline == before)
    }

    @Test func testPauseOffsetsAreIdenticalForAudioAndVideo() {
        var timeline = CaptureTimeline()
        timeline.anchor(at: 100)
        timeline.pause(at: 102)
        #expect(timeline.presentationTime(for: 103) == nil)
        #expect(timeline.duration(at: 108) == 2)
        timeline.resume(at: 110)
        #expect(timeline.presentationTime(for: 109.9) == nil, "Queued pre-resume buffers must be discarded")
        #expect(abs(timeline.presentationTime(for: 110.1)! - 2.1) < 0.00001)
        timeline.pause(at: 112)
        timeline.resume(at: 114)
        #expect(abs(timeline.presentationTime(for: 115)! - 5) < 0.00001)
        #expect(abs(timeline.duration(at: 115) - 5) < 0.00001)
    }

    @Test func testPauseBeforeFirstFrameDoesNotCreateNegativeTimeline() {
        var timeline = CaptureTimeline()
        timeline.pause(at: 10)
        timeline.resume(at: 20)
        timeline.anchor(at: 20.1)
        #expect(timeline.presentationTime(for: 20.1) == 0)
    }
}
