import AppKit
import Testing
import FrameRecCore
@testable import FrameRecUI

@Suite(.serialized)
@MainActor
struct RegionSelectionTests {
    private func display() -> SelectionDisplay {
        SelectionDisplay(id: 42, frame: CGRect(x: -1200, y: -100, width: 1200, height: 900),
                         visibleFrame: CGRect(x: -1200, y: -100, width: 1200, height: 875), scale: 2)
    }

    @Test func overlayKeepsMouseDragsAndDoesNotHideOnDeactivate() throws {
        _ = NSApplication.shared
        let panel = RegionSelector.makePanel(display: display())
        defer { panel.close() }
        let view = try #require(panel.contentView as? SelectionView)
        #expect(!panel.hidesOnDeactivate)
        #expect(!panel.isMovable)
        #expect(!panel.isMovableByWindowBackground)
        #expect(!panel.ignoresMouseEvents)
        #expect(panel.canBecomeMain)
        #expect(!view.mouseDownCanMoveWindow)
        #expect(view.acceptsFirstMouse(for: nil))
        #expect(view.needsPanelToBecomeKey)
    }

    @Test func downDragUpPublishesTheSelectedDisplayAndRectangle() throws {
        _ = NSApplication.shared
        let display = display()
        let panel = RegionSelector.makePanel(display: display)
        defer { panel.close() }
        let view = try #require(panel.contentView as? SelectionView)
        var output: CaptureSelection?
        view.onChange = { output = display.selection(localRect: $0) }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 120), window: panel))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 700, y: 520), window: panel))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 700, y: 520), window: panel))
        let selection = try #require(output)
        #expect(selection.displayID == 42)
        #expect(selection.rect == CGRect(x: -1100, y: 20, width: 600, height: 400))
        #expect(selection.width == 1200)
        #expect(selection.height == 800)
        let frame = try #require(RegionGeometry.toolbarFrame(size: CGSize(width: 475, height: 66),
                         region: selection.rect, preferredScreen: selection.visibleFrame, otherScreens: []))
        #expect(!frame.intersects(selection.rect))
    }

    @Test func aSecondDragMovesTheRegionInsteadOfMovingTheOverlayWindow() throws {
        _ = NSApplication.shared
        let panel = RegionSelector.makePanel(display: display())
        defer { panel.close() }
        let originalFrame = panel.frame
        let view = try #require(panel.contentView as? SelectionView)
        view.selection = CGRect(x: 100, y: 120, width: 600, height: 400)
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 300, y: 300), window: panel))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 350, y: 340), window: panel))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 350, y: 340), window: panel))
        #expect(view.selection == CGRect(x: 150, y: 160, width: 600, height: 400))
        #expect(panel.frame == originalFrame)
    }

    @Test func tooSmallARegionIsClearedWithoutPublishingASelection() throws {
        _ = NSApplication.shared
        let panel = RegionSelector.makePanel(display: display())
        defer { panel.close() }
        let view = try #require(panel.contentView as? SelectionView)
        var published = false
        var cleared = false
        view.onChange = { _ in published = true }
        view.onClear = { cleared = true }
        view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: panel))
        view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 105, y: 105), window: panel))
        view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 105, y: 105), window: panel))
        #expect(view.selection == nil)
        #expect(!published)
        #expect(cleared)
    }

    @Test func cursorRectIsValidEvenDuringTheFirstPixelsOfADrag() throws {
        _ = NSApplication.shared
        let panel = RegionSelector.makePanel(display: display())
        defer { panel.close() }
        let view = try #require(panel.contentView as? SelectionView)
        for side in [CGFloat(0), 1, 5, 12] {
            view.selection = CGRect(x: 100, y: 100, width: side, height: side)
            #expect(view.moveCursorRect == nil)
            panel.resetCursorRects()
        }
        view.selection = CGRect(x: 100, y: 100, width: 100, height: 80)
        let cursor = try #require(view.moveCursorRect)
        #expect(!cursor.isNull)
        #expect(cursor == CGRect(x: 106, y: 106, width: 88, height: 68))
        panel.resetCursorRects()
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }
}
