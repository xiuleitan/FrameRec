import Foundation
import AVFoundation

public enum MovieFormat: String, CaseIterable, Codable, Sendable {
    case mp4, mov
    public var label: String { rawValue.uppercased() }
    public var fileType: AVFileType { self == .mp4 ? .mp4 : .mov }
}

public struct Recording: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var fileName: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var duration: Double
    public var width: Int
    public var height: Int
    public var frameRate: Int
    public var format: MovieFormat
    public var title: String

    public init(id: UUID = UUID(), fileName: String, createdAt: Date = Date(),
                duration: Double, width: Int, height: Int, frameRate: Int,
                format: MovieFormat, title: String) {
        self.id = id
        self.fileName = fileName
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.duration = duration
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.format = format
        self.title = title
    }
}

public enum FrameRecError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

public func durationLabel(_ seconds: Double, precise: Bool = false) -> String {
    let value = seconds.isFinite ? max(0, seconds) : 0
    let total = Int(value)
    let hours = total / 3600
    let minutes = (total / 60) % 60
    let label = hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, total % 60)
        : String(format: "%02d:%02d", minutes, total % 60)
    return precise ? label + String(format: ".%02d", Int((value - Double(total)) * 100)) : label
}
