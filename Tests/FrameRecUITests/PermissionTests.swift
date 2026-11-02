import Testing
@testable import FrameRecUI

@MainActor
struct PermissionTests {
    @Test func grantedAccessDoesNotRequestAgain() {
        var requests = 0
        let permission = ScreenRecordingPermission(preflight: { true }, request: { requests += 1; return true })
        #expect(permission.requestAccess())
        #expect(requests == 0)
    }

    @Test func firstRequestRechecksAuthorization() {
        var allowed = false
        var requests = 0
        let permission = ScreenRecordingPermission(preflight: { allowed }, request: { requests += 1; allowed = true; return true })
        #expect(!permission.isAuthorized)
        #expect(permission.requestAccess())
        #expect(requests == 1)
        #expect(permission.requestAccess())
        #expect(requests == 1)
    }

    @Test func requestingAccessWithoutEffectivePermissionDoesNotEnterCapture() {
        var requests = 0
        let permission = ScreenRecordingPermission(preflight: { false }, request: { requests += 1; return true })
        #expect(!permission.requestAccess())
        #expect(!permission.isAuthorized)
        #expect(requests == 1)
    }

    @Test func deniedAccessStaysUnauthorized() {
        let permission = ScreenRecordingPermission(preflight: { false }, request: { false })
        #expect(!permission.requestAccess())
    }
}
