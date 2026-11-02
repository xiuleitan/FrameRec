import CoreGraphics

/// The request's return value alone doesn't prove this process can capture.
/// Always recheck; some macOS permission changes require an app restart.
@MainActor
public final class ScreenRecordingPermission {
    private let preflight: () -> Bool
    private let request: () -> Bool

    public init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
                request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    public var isAuthorized: Bool { preflight() }

    @discardableResult
    public func requestAccess() -> Bool {
        if preflight() { return true }
        _ = request()
        return preflight()
    }
}
