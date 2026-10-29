import AppKit
import XCTest

@MainActor
final class MenuBarStatusItemControllerNotificationTests: XCTestCase {
    func testPollingReconcilesMissingOrHiddenWindowWithoutCloseNotification() {
        let controller = MenuBarStatusItemController()
        let closed = expectation(forNotification: .codexpanelStatusItemMenuDidClose, object: controller)
        closed.expectedFulfillmentCount = 3
        closed.assertForOverFulfill = true

        controller.menuWillOpen()
        XCTAssertFalse(controller.synchronizePresentation())
        XCTAssertFalse(controller.synchronizePresentation())

        let window = VisibilityWindow()
        controller.attachMenuWindow(window)
        controller.menuWillOpen()
        XCTAssertFalse(controller.synchronizePresentation())

        // MenuBarExtra 的窗口仍标为 visible，但原生展示场景已经隐藏。
        window.reportsVisible = true
        controller.menuWillOpen()
        XCTAssertFalse(controller.synchronizePresentation())
        wait(for: [closed], timeout: 0.1)
    }

    func testDetachingCurrentWindowClosesMenuButOldWindowDoesNot() {
        let controller = MenuBarStatusItemController()
        let oldWindow = VisibilityWindow()
        let currentWindow = VisibilityWindow()
        controller.attachMenuWindow(oldWindow)
        controller.attachMenuWindow(currentWindow)
        controller.menuWillOpen()
        var closeCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .codexpanelStatusItemMenuDidClose, object: controller, queue: .main
        ) { _ in closeCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        let closed = expectation(forNotification: .codexpanelStatusItemMenuDidClose, object: controller)
        closed.assertForOverFulfill = true
        controller.detachMenuWindow(oldWindow)
        XCTAssertEqual(closeCount, 0)
        controller.detachMenuWindow(currentWindow)
        XCTAssertEqual(closeCount, 1)
        XCTAssertFalse(controller.synchronizePresentation())
        wait(for: [closed], timeout: 0.1)
    }

    private final class VisibilityWindow: NSWindow {
        var reportsVisible = false
        override var isVisible: Bool { self.reportsVisible }
        override var occlusionState: NSWindow.OcclusionState { [] }
    }

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
