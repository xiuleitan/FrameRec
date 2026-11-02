import Foundation

public enum RegionGeometry {
    /// AppKit uses a global bottom-left origin; ScreenCaptureKit uses display-local top-left points.
    public static func captureRect(region: CGRect, screen: CGRect) -> CGRect {
        CGRect(x: region.minX - screen.minX, y: screen.maxY - region.maxY,
               width: region.width, height: region.height)
    }

    public static func clamp(_ rectangle: CGRect, to bounds: CGRect) -> CGRect {
        let size = CGSize(width: min(rectangle.width, bounds.width), height: min(rectangle.height, bounds.height))
        return CGRect(x: min(max(rectangle.minX, bounds.minX), bounds.maxX - size.width),
                      y: min(max(rectangle.minY, bounds.minY), bounds.maxY - size.height),
                      width: size.width, height: size.height)
    }

    /// Returns nil when no display has enough space outside the capture region.
    public static func toolbarFrame(size: CGSize, region: CGRect,
                                    preferredScreen: CGRect, otherScreens: [CGRect],
                                    gap: CGFloat = 12) -> CGRect? {
        let candidates = [
            CGRect(x: region.midX - size.width / 2, y: region.minY - gap - size.height, width: size.width, height: size.height),
            CGRect(x: region.midX - size.width / 2, y: region.maxY + gap, width: size.width, height: size.height),
            CGRect(x: region.minX - gap - size.width, y: region.midY - size.height / 2, width: size.width, height: size.height),
            CGRect(x: region.maxX + gap, y: region.midY - size.height / 2, width: size.width, height: size.height),
        ]
        for candidate in candidates {
            guard preferredScreen.width >= size.width, preferredScreen.height >= size.height else { continue }
            let adjusted = clamp(candidate, to: preferredScreen)
            if !adjusted.intersects(region.insetBy(dx: -gap / 2, dy: -gap / 2)) { return adjusted }
        }
        for screen in otherScreens where screen.width >= size.width && screen.height >= size.height {
            let candidate = CGRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - gap,
                                   width: size.width, height: size.height)
            let adjusted = clamp(candidate, to: screen)
            if !adjusted.intersects(region.insetBy(dx: -gap / 2, dy: -gap / 2)) { return adjusted }
        }
        return nil
    }
}
