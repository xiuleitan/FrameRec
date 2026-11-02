import AppKit
import FrameRecCore

public final class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}

/// Unlike a recording control bar, the selection surface temporarily owns focus.
/// This also keeps native event routing from falling back to a history window.
final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
public final class RegionSelector {
    private var panels: [SelectionPanel] = []
    private var views: [SelectionView] = []
    public var onSelection: ((CaptureSelection) -> Void)?
    public var onClear: (() -> Void)?
    public var onCancel: (() -> Void)?

    public init() {}

    public func show() {
        close()
        var keyPanel: SelectionPanel?
        for screen in NSScreen.screens {
            guard let display = SelectionDisplay(screen: screen) else { continue }
            let panel = Self.makePanel(display: display)
            guard let view = panel.contentView as? SelectionView else { continue }
            view.onChange = { [weak self, weak view] rect in
                guard let self, let view else { return }
                for other in self.views where other !== view { other.selection = nil }
                self.onSelection?(display.selection(localRect: rect))
            }
            view.onCancel = { [weak self] in self?.onCancel?() }
            view.onClear = { [weak self, weak view] in
                guard let self else { return }
                for other in self.views where other !== view { other.selection = nil }
                self.onClear?()
            }
            panels.append(panel)
            views.append(view)
            panel.orderFrontRegardless()
            if display.frame.contains(NSEvent.mouseLocation) { keyPanel = panel }
        }
        // Status-item menus don't activate their owning utility app. Activate only
        // after the menu has closed, and keep every display's overlay visible.
        NSApp.activate(ignoringOtherApps: true)
        if let panel = keyPanel ?? panels.first {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(panel.contentView)
        }
        NSCursor.crosshair.set()
    }

    static func makePanel(display: SelectionDisplay) -> SelectionPanel {
        let panel = SelectionPanel(contentRect: display.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "FrameRec · 框选录屏区域"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let view = SelectionView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.scale = display.scale
        panel.contentView = view
        return panel
    }

    public func close() {
        panels.forEach { $0.close() }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
    }
}

/// Snapshot display identity and coordinates for this selection session instead
/// of relying on a weak NSScreen reference inside mouse callbacks.
struct SelectionDisplay {
    let id: CGDirectDisplayID
    let frame: CGRect
    let visibleFrame: CGRect
    let scale: CGFloat

    init(id: CGDirectDisplayID, frame: CGRect, visibleFrame: CGRect, scale: CGFloat) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame; self.scale = scale
    }

    init?(screen: NSScreen) {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        self.init(id: number.uint32Value, frame: screen.frame, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
    }

    func selection(localRect: CGRect) -> CaptureSelection {
        CaptureSelection(displayID: id, screenFrame: frame, visibleFrame: visibleFrame,
                         rect: localRect.offsetBy(dx: frame.minX, dy: frame.minY), scale: scale)
    }
}

final class SelectionView: NSView {
    var scale: CGFloat = 1
    var selection: CGRect? { didSet { needsDisplay = true; window?.invalidateCursorRects(for: self) } }
    var onChange: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onClear: (() -> Void)?
    private var anchor = CGPoint.zero
    private var initialRect = CGRect.zero
    private enum DragMode { case create, move, resize(Int) }
    private var mode: DragMode = .create

    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    // Transparent NSViews default to allowing mouse-down window drags. A region
    // gesture must stay in this view for its entire down/drag/up sequence.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func handlePoints(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        let selection = drawableSelection
        if let selection { path.appendRect(selection); path.windingRule = .evenOdd }
        NSColor.black.withAlphaComponent(0.35).setFill()
        path.fill()
        guard let selection else {
            let text = "拖动框选录屏区域 · Esc 取消"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 21, weight: .medium), .foregroundColor: NSColor.white,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
            return
        }
        FrameRecTheme.color.setStroke()
        let outline = NSBezierPath(rect: selection)
        outline.lineWidth = 2
        outline.stroke()
        for point in handlePoints(selection) {
            let handle = NSBezierPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8), xRadius: 2, yRadius: 2)
            NSColor.white.setFill(); handle.fill()
        }
        let text = "\(Int(selection.width * scale) / 2 * 2) × \(Int(selection.height * scale) / 2 * 2)"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let label = CGRect(x: max(8, min(selection.minX, bounds.maxX - size.width - 24)),
                           y: min(bounds.maxY - 34, selection.maxY + 10), width: size.width + 16, height: 25)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: label, xRadius: 6, yRadius: 6).fill()
        (text as NSString).draw(at: CGPoint(x: label.minX + 8, y: label.minY + 5), withAttributes: attrs)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        // CGRect.insetBy returns CGRect.null (infinite origin) while a new
        // selection is smaller than the inset. AppKit traps on that rectangle.
        if let rect = moveCursorRect { addCursorRect(rect, cursor: .openHand) }
    }

    private var drawableSelection: CGRect? {
        guard let selection, !selection.isNull, !selection.isInfinite, !selection.isEmpty else { return nil }
        return selection
    }

    var moveCursorRect: CGRect? {
        guard let selection = drawableSelection, selection.width > 12, selection.height > 12 else { return nil }
        let rect = selection.insetBy(dx: 6, dy: 6).intersection(bounds)
        return !rect.isNull && !rect.isEmpty && !rect.isInfinite ? rect : nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        anchor = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        if let selection {
            initialRect = selection
            if let handle = handlePoints(selection).firstIndex(where: { abs($0.x - anchor.x) <= 9 && abs($0.y - anchor.y) <= 9 }) {
                mode = .resize(handle)
            } else if selection.contains(anchor) { mode = .move }
            else { mode = .create }
        } else { mode = .create }
        if case .create = mode {
            onClear?()
            selection = CGRect(origin: anchor, size: .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        let point = CGPoint(x: min(max(raw.x, 0), bounds.width), y: min(max(raw.y, 0), bounds.height))
        var rect: CGRect
        switch mode {
        case .create:
            rect = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                          width: abs(point.x - anchor.x), height: abs(point.y - anchor.y))
        case .move:
            rect = RegionGeometry.clamp(initialRect.offsetBy(dx: point.x - anchor.x, dy: point.y - anchor.y), to: bounds)
        case .resize(let index):
            var x1 = initialRect.minX, x2 = initialRect.maxX, y1 = initialRect.minY, y2 = initialRect.maxY
            if [0, 6, 7].contains(index) { x1 = point.x }
            if [2, 3, 4].contains(index) { x2 = point.x }
            if [0, 1, 2].contains(index) { y1 = point.y }
            if [4, 5, 6].contains(index) { y2 = point.y }
            rect = CGRect(x: min(x1, x2), y: min(y1, y2), width: abs(x2 - x1), height: abs(y2 - y1))
        }
        rect = rect.intersection(bounds)
        selection = rect
        if rect.width >= 24, rect.height >= 24 { onChange?(rect) }
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width >= 24, selection.height >= 24 { onChange?(selection) }
        else { selection = nil; onClear?() }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }
}

@MainActor
public final class RegionBorder {
    private var panel: NSPanel?
    public init() {}
    public func show(_ rect: CGRect, paused: Bool) {
        if panel == nil {
            let panel = NSPanel(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            self.panel = panel
        }
        panel?.setFrame(rect.insetBy(dx: -3, dy: -3), display: true)
        let view = BorderView(frame: CGRect(origin: .zero, size: rect.insetBy(dx: -3, dy: -3).size))
        view.paused = paused
        panel?.contentView = view
        panel?.orderFrontRegardless()
    }
    public func close() { panel?.close(); panel = nil }
}

final class BorderView: NSView {
    var paused = false
    override func draw(_ dirtyRect: NSRect) {
        (paused ? NSColor.systemOrange : FrameRecTheme.color).setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 2
        if paused { path.setLineDash([6, 4], count: 2, phase: 0) }
        path.stroke()
    }
}
