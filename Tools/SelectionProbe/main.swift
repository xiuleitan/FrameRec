import AppKit
import FrameRecCore
import FrameRecUI

// A development-only host for the production region selector. It draws overlays
// and reports mouse selections; it never requests permission or captures content.
@MainActor
final class ProbeDelegate: NSObject, NSApplicationDelegate {
    let selector = RegionSelector()
    var status: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        selector.onCancel = { NSApp.terminate(nil) }
        selector.onSelection = { [weak self] selection in self?.report(selection) }
        selector.show()
    }

    private func report(_ selection: CaptureSelection) {
        let size = CGSize(width: 400, height: 72)
        let otherScreens = NSScreen.screens.filter { $0.frame != selection.screenFrame }.map(\.visibleFrame)
        let frame = RegionGeometry.toolbarFrame(size: size, region: selection.rect,
                                                 preferredScreen: selection.visibleFrame, otherScreens: otherScreens)
        if let frame {
            if status == nil {
                let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "FrameRec · 选区事件检查"
                panel.backgroundColor = .windowBackgroundColor
                panel.hidesOnDeactivate = false
                panel.level = .floating
                panel.isReleasedWhenClosed = false
                panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                status = panel
            }
            let label = NSTextField(labelWithString: "已接收选区 \(selection.width) × \(selection.height) · Esc 退出检查")
            label.frame = CGRect(x: 15, y: 23, width: 370, height: 25)
            label.alignment = .center
            status?.contentView = NSView(frame: CGRect(origin: .zero, size: size))
            status?.contentView?.addSubview(label)
            status?.setFrame(frame, display: true)
            status?.orderFrontRegardless()
        }
        var result: [String: Any] = [
            "displayID": selection.displayID,
            "region": [selection.rect.minX, selection.rect.minY, selection.rect.width, selection.rect.height],
            "width": selection.width,
            "height": selection.height,
        ]
        if let frame {
            result["toolbar"] = [frame.minX, frame.minY, frame.width, frame.height]
            result["toolbarOutside"] = !frame.intersects(selection.rect)
        }
        let output = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("selection-probe.json")
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output, options: .atomic)
        }
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    let delegate = ProbeDelegate()
    application.setActivationPolicy(.accessory)
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
