import XCTest

final class MenuBarStatusItemIdentityTests: XCTestCase {
    func testPopoverWidthStaysCompact() {
        XCTAssertEqual(MenuBarStatusItemIdentity.popoverContentWidth, 300)
    }

    func testIdentityConstantsStayStable() {
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityLabel, "codexpanel")
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityIdentifier, "codexpanel.status-item")
    }
}
