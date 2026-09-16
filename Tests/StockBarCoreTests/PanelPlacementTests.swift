import XCTest
import CoreGraphics
@testable import StockBarCore

final class PanelPlacementTests: XCTestCase {
    func testPanelStaysBelowNotchAndWithinScreenEdges() {
        let visible = CGRect(x: 0, y: 0, width: 1728, height: 1084)
        for x: CGFloat in [0, 742, 1710] {
            let frame = PanelPlacement.frame(anchor: CGRect(x: x, y: 1087, width: 22, height: 28), size: CGSize(width: 480, height: 600), visible: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertLessThanOrEqual(frame.maxY, 1076)
        }
    }
    func testExternalScreenWithNegativeOrigin() {
        let visible = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let frame = PanelPlacement.frame(anchor: CGRect(x: -1900, y: 880, width: 22, height: 28), size: CGSize(width: 480, height: 600), visible: visible)
        XCTAssertTrue(visible.contains(frame))
    }
    func testOldPreferencesKeepIslandDisabled() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        XCTAssertFalse(prefs.islandEnabled)
        XCTAssertEqual(prefs.islandGap, 0)
    }
}
