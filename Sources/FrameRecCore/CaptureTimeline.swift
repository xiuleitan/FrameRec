import Foundation

/// All inputs use the host clock, shared by ScreenCaptureKit's audio and video samples.
public struct CaptureTimeline: Sendable {
    public private(set) var origin: Double?
    public private(set) var pausedAt: Double?
    public private(set) var removedDuration = 0.0
    private var validFrom = -Double.infinity

    public init() {}
    public mutating func anchor(at time: Double) {
        if origin == nil {
            origin = time
            // A pause before the first delivered frame must not shift the new origin.
            removedDuration = 0
        }
    }
    public mutating func pause(at time: Double) {
        guard pausedAt == nil else { return }
        pausedAt = time
    }
    public mutating func resume(at time: Double) {
        guard let pausedAt else { return }
        removedDuration += max(0, time - pausedAt)
        self.pausedAt = nil
        validFrom = time
    }
    public func presentationTime(for sourceTime: Double) -> Double? {
        guard pausedAt == nil, let origin, sourceTime >= validFrom else { return nil }
        let adjusted = sourceTime - origin - removedDuration
        return adjusted >= -0.000001 ? max(0, adjusted) : nil
    }
    public func duration(at time: Double) -> Double {
        guard let origin else { return 0 }
        return max(0, (pausedAt ?? time) - origin - removedDuration)
    }
}
