import AppKit
import XCTest

@MainActor
final class MenuBarStatusItemControllerNotificationTests: XCTestCase {
    func testNativeMenuWillOpenPostsMenuWillOpenNotification() {
        let controller = MenuBarStatusItemController.shared
        controller.menuDidClose()
        let expectation = expectation(
            forNotification: .codexpanelStatusItemMenuWillOpen,
            object: controller
        )

        controller.menuWillOpen()

        wait(for: [expectation], timeout: 0.1)
    }

    func testNativeMenuDidClosePostsMenuDidCloseNotification() {
        let controller = MenuBarStatusItemController.shared
        controller.menuWillOpen()
        let expectation = expectation(
            forNotification: .codexpanelStatusItemMenuDidClose,
            object: controller
        )

        controller.menuDidClose()

        wait(for: [expectation], timeout: 0.1)
    }

    func testRepeatedWindowNotificationsDoNotRepeatOpenOrCloseEvents() {
        let controller = MenuBarStatusItemController.shared
        controller.menuDidClose()
        let opened = expectation(forNotification: .codexpanelStatusItemMenuWillOpen, object: controller)
        let closed = expectation(forNotification: .codexpanelStatusItemMenuDidClose, object: controller)
        opened.expectedFulfillmentCount = 2
        closed.expectedFulfillmentCount = 2
        opened.assertForOverFulfill = true
        closed.assertForOverFulfill = true

        for _ in 0..<2 {
            controller.menuWillOpen()
            controller.menuWillOpen()
            controller.menuDidClose()
            controller.menuDidClose()
        }

        wait(for: [opened, closed], timeout: 0.1)
    }
}
