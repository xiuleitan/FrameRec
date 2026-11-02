import Foundation

public struct SourceRange: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }
    public init(start: Double, end: Double) { self.start = start; self.end = end }
}

/// Ranges remain in original-source coordinates, even after repeated edits.
public struct EditTimeline: Equatable, Sendable {
    public private(set) var ranges: [SourceRange]
    public var duration: Double { ranges.reduce(0) { $0 + $1.duration } }

    public init(duration: Double) { ranges = duration > 0 ? [SourceRange(start: 0, end: duration)] : [] }

    public mutating func remove(start: Double, end: Double, minimumRemaining: Double = 1.0 / 30) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.001 else {
            throw FrameRecError.message("请选择有效的删除区间。")
        }
        guard duration - (end - start) >= minimumRemaining - 0.00001 else {
            throw FrameRecError.message("至少需要保留一帧画面。")
        }
        var cursor = 0.0
        var kept: [SourceRange] = []
        for range in ranges {
            let segmentStart = cursor
            let segmentEnd = cursor + range.duration
            let overlapStart = max(start, segmentStart)
            let overlapEnd = min(end, segmentEnd)
            if overlapStart >= overlapEnd {
                kept.append(range)
            } else {
                if overlapStart > segmentStart + 0.000001 {
                    kept.append(SourceRange(start: range.start, end: range.start + overlapStart - segmentStart))
                }
                if overlapEnd < segmentEnd - 0.000001 {
                    kept.append(SourceRange(start: range.start + overlapEnd - segmentStart, end: range.end))
                }
            }
            cursor = segmentEnd
        }
        ranges = kept
    }

    public func sourceTime(at editedTime: Double) -> Double {
        var remaining = max(0, editedTime)
        for range in ranges {
            if remaining < range.duration { return range.start + remaining }
            remaining -= range.duration
        }
        return ranges.last?.end ?? 0
    }
}
