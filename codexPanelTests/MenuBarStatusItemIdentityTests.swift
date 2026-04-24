import AppKit
import XCTest

final class MenuBarStatusItemIdentityTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        self.suiteName = "MenuBarStatusItemIdentityTests.\(UUID().uuidString)"
        self.userDefaults = UserDefaults(suiteName: self.suiteName)
        self.userDefaults.removePersistentDomain(forName: self.suiteName)
    }

    override func tearDown() {
        self.userDefaults.removePersistentDomain(forName: self.suiteName)
        self.userDefaults = nil
        self.suiteName = nil
        super.tearDown()
    }

    func testPopoverWidthStaysCompact() {
        XCTAssertEqual(MenuBarStatusItemIdentity.popoverContentWidth, 300)
    }

    func testIdentityConstantsStayStable() {
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityLabel, "codexpanel")
        XCTAssertEqual(MenuBarStatusItemIdentity.accessibilityIdentifier, "codexpanel.status-item")
        XCTAssertEqual(
            MenuBarStatusItemIdentity.statusItemAutosaveName,
            "com.codexpanel.menu-bar-status-item"
        )
        XCTAssertFalse(String(MenuBarStatusItemIdentity.statusItemAutosaveName).contains("codexAppBar"))
    }

    func testStatusItemBehaviorAllowsRemovalWithoutTermination() {
        let behavior = MenuBarStatusItemIdentity.statusItemBehavior

        XCTAssertTrue(behavior.contains(.removalAllowed))
        XCTAssertFalse(behavior.contains(.terminationOnRemoval))
    }

    func testRepairVisibilityMigratesLegacyCodexPanelPreferenceIntoCurrentNamedKeys() {
        self.userDefaults.set(true, forKey: "codexpanel.menu-bar-extra.is-inserted")

        MenuBarStatusItemIdentity.repairVisibilityIfNeeded(userDefaults: self.userDefaults)

        XCTAssertEqual(
            self.userDefaults.object(forKey: "NSStatusItem VisibleCC com.codexpanel.menu-bar-status-item") as? Bool,
            true
        )
        XCTAssertEqual(
            self.userDefaults.object(forKey: "NSStatusItem Visible com.codexpanel.menu-bar-status-item") as? Bool,
            true
        )
    }

    func testRepairVisibilityIgnoresAnonymousSystemItemKeys() {
        self.userDefaults.set(false, forKey: "NSStatusItem Visible Item-0")

        XCTAssertFalse(
            MenuBarStatusItemIdentity.shouldRepairVisibility(
                domain: self.userDefaults.dictionaryRepresentation()
            )
        )
    }

    func testResolvedVisibilityPrefersCurrentNamedHiddenState() {
        XCTAssertFalse(
            MenuBarStatusItemIdentity.resolvedVisibility(
                domain: [
                    "codexpanel.menu-bar-extra.is-inserted": true,
                    "NSStatusItem VisibleCC com.codexpanel.menu-bar-status-item": false,
                ]
            )
        )
    }

    func testLegacyNamedVisibilityKeysAreEmpty() {
        XCTAssertTrue(MenuBarStatusItemIdentity.legacyNamedVisibleKeys.isEmpty)
    }

    func testMenuBarStatusItemControllerResolvedVisibilityUsesCurrentNamedPreference() {
        self.userDefaults.set(false, forKey: "NSStatusItem VisibleCC com.codexpanel.menu-bar-status-item")

        XCTAssertFalse(MenuBarStatusItemController.resolvedVisibilityPreference(userDefaults: self.userDefaults))

        self.userDefaults.set(true, forKey: "NSStatusItem VisibleCC com.codexpanel.menu-bar-status-item")

        XCTAssertTrue(MenuBarStatusItemController.resolvedVisibilityPreference(userDefaults: self.userDefaults))
    }
}
