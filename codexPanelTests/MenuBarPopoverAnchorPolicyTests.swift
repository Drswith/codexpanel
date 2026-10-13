import AppKit
import XCTest

final class MenuBarPopoverAnchorPolicyTests: XCTestCase {
    func testCollapsedOffscreenAndEmptyAnchorsAreRejected() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(MenuBarPopoverAnchorPolicy.isUsable(CGRect(x: -10000, y: 875, width: 24, height: 25), on: screen))
        XCTAssertFalse(MenuBarPopoverAnchorPolicy.isUsable(.zero, on: screen))
        XCTAssertTrue(MenuBarPopoverAnchorPolicy.isUsable(CGRect(x: 1200, y: 875, width: 24, height: 25), on: screen))
    }

    func testSecondaryScreenWithNegativeOriginIsAccepted() {
        let screen = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertTrue(MenuBarPopoverAnchorPolicy.isUsable(CGRect(x: -300, y: 855, width: 24, height: 25), on: screen))
    }

    func testMovingOrResizingAnchorMustSettleBeforePresentation() {
        let frame = CGRect(x: 100, y: 875, width: 24, height: 25)
        XCTAssertFalse(MenuBarPopoverAnchorPolicy.isStable(frame, previous: nil))
        XCTAssertFalse(MenuBarPopoverAnchorPolicy.isStable(frame.offsetBy(dx: 50, dy: 0), previous: frame))
        XCTAssertFalse(MenuBarPopoverAnchorPolicy.isStable(CGRect(x: 100, y: 875, width: 60, height: 25), previous: frame))
        XCTAssertTrue(MenuBarPopoverAnchorPolicy.isStable(frame, previous: frame))
    }
}
