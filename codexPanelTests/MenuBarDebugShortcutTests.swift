import Carbon
import XCTest

final class MenuBarDebugShortcutTests: XCTestCase {
    func testShortcutIdentifiersAndCombinationsAreUnique() {
        let shortcuts = MenuBarGlobalShortcut.all
        XCTAssertEqual(Set(shortcuts.map(\.identifier)).count, shortcuts.count)
        XCTAssertEqual(Set(shortcuts.map { "\($0.modifiers):\($0.keyCode)" }).count, shortcuts.count)
        XCTAssertTrue(shortcuts.contains(.primary))
    }

    #if DEBUG
    func testDebugMenuOpenUsesUncommonGlobalCombination() {
        let shortcut = MenuBarGlobalShortcut.debugMenuOpen
        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_9))
        XCTAssertEqual(shortcut.modifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(shortcut.identifier, 3)
        XCTAssertTrue(MenuBarGlobalShortcut.all.contains(shortcut))
    }
    #else
    func testReleaseRegistersOnlyPrimaryShortcut() {
        XCTAssertEqual(MenuBarGlobalShortcut.all, [.primary])
    }
    #endif
}
