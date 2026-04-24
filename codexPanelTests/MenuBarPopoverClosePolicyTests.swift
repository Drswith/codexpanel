import CoreGraphics
import XCTest

final class MenuBarPopoverClosePolicyTests: XCTestCase {
    func testHoverPanelPreventsPopoverCloseWhileMouseIsInside() {
        let hoverPanelFrame = CGRect(x: 400, y: 220, width: 272, height: 196)

        XCTAssertFalse(
            MenuBarPopoverClosePolicy.shouldClosePopover(
                mouseLocation: CGPoint(x: 520, y: 300),
                protectedWindowFrames: [hoverPanelFrame]
            )
        )
    }

    func testPopoverCanCloseWhenMouseIsOutsideProtectedFrames() {
        let hoverPanelFrame = CGRect(x: 400, y: 220, width: 272, height: 196)

        XCTAssertTrue(
            MenuBarPopoverClosePolicy.shouldClosePopover(
                mouseLocation: CGPoint(x: 720, y: 300),
                protectedWindowFrames: [hoverPanelFrame]
            )
        )
    }
}
