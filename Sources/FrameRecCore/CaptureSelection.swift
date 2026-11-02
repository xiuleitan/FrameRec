import CoreGraphics
import Foundation

public struct CaptureSelection {
    public let displayID: CGDirectDisplayID
    public let screenFrame: CGRect
    public let visibleFrame: CGRect
    public let rect: CGRect
    public let scale: CGFloat

    public init(displayID: CGDirectDisplayID, screenFrame: CGRect, visibleFrame: CGRect, rect: CGRect, scale: CGFloat) {
        self.displayID = displayID
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.rect = rect
        self.scale = scale
    }

    public var width: Int { max(2, Int((rect.width * scale).rounded()) / 2 * 2) }
    public var height: Int { max(2, Int((rect.height * scale).rounded()) / 2 * 2) }
}
