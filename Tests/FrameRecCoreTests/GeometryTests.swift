import Foundation
import Testing
@testable import FrameRecCore

final class GeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 475, height: 66)

    @Test func testToolbarAvoidsSelectionAndStaysOnScreen() throws {
        let region = CGRect(x: 200, y: 200, width: 800, height: 500)
        let frame = try #require(RegionGeometry.toolbarFrame(size: size, region: region, preferredScreen: screen, otherScreens: []))
        #expect(screen.contains(frame))
        #expect(frame.maxY < region.minY)
        #expect(!frame.intersects(region))
    }

    @Test func testToolbarMovesAboveSelectionAtBottomEdge() throws {
        let region = CGRect(x: 0, y: 0, width: 1440, height: 600)
        let frame = try #require(RegionGeometry.toolbarFrame(size: size, region: region, preferredScreen: screen, otherScreens: []))
        #expect(frame.minY > region.maxY)
        #expect(!frame.intersects(region))
    }

    @Test func testFullScreenSelectionUsesOtherDisplayOrMenuBarFallback() throws {
        let other = CGRect(x: -1920, y: 200, width: 1920, height: 1080)
        let frame = try #require(RegionGeometry.toolbarFrame(size: size, region: screen, preferredScreen: screen, otherScreens: [other]))
        #expect(other.contains(frame))
        #expect(RegionGeometry.toolbarFrame(size: size, region: screen, preferredScreen: screen, otherScreens: []) == nil)
    }

    @Test func testMixedDisplayOriginsAreConvertedToLocalTopLeftPoints() {
        let display = CGRect(x: -1920, y: -300, width: 1920, height: 1080)
        let region = CGRect(x: -1700, y: 100, width: 600, height: 400)
        #expect(RegionGeometry.captureRect(region: region, screen: display) == CGRect(x: 220, y: 280, width: 600, height: 400))
    }
}
