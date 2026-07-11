import AppKit
import XCTest

final class MenuBarPopoverSizingTests: XCTestCase {
    private let macOS14 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
    private let macOS15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)

    func testInitialSizeUsesStableWidthAndLegacyDefaultHeightBeforeMacOS15() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200, version: self.macOS14)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight(for: self.macOS14))
    }

    func testInitialSizeAddsExtraVerticalCompensationOnMacOS15() {
        let size = MenuBarPopoverSizing.initialSize(availableHeight: 1200, version: self.macOS15)

        XCTAssertEqual(size.width, MenuBarStatusItemIdentity.popoverContentWidth)
        XCTAssertEqual(size.height, MenuBarPopoverSizing.defaultHeight(for: self.macOS15))
        XCTAssertGreaterThan(
            MenuBarPopoverSizing.defaultHeight(for: self.macOS15),
            MenuBarPopoverSizing.defaultHeight(for: self.macOS14)
        )
    }

    func testClampedHeightCapsToAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 2000,
                availableHeight: 1400,
                version: self.macOS15
            ),
            1400
        )
    }

    func testClampedHeightFallsBackToConfiguredMaximumWhenAvailableHeightIsUnknown() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 2000,
                availableHeight: nil,
                version: self.macOS14
            ),
            MenuBarPopoverSizing.maximumHeight(for: self.macOS14)
        )
    }

    func testClampedHeightRespectsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 600,
                availableHeight: 500,
                version: self.macOS15
            ),
            500
        )
    }

    func testClampedHeightFollowsShortContentHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.clampedHeight(
                desiredHeight: 100,
                availableHeight: 200,
                version: self.macOS15
            ),
            100
        )
    }

    func testMeasuredContentWidthMustMatchPopoverWidth() {
        XCTAssertTrue(
            MenuBarPopoverSizing.acceptsMeasuredContentWidth(
                MenuBarStatusItemIdentity.popoverContentWidth
            )
        )
        XCTAssertFalse(MenuBarPopoverSizing.acceptsMeasuredContentWidth(1))
        XCTAssertFalse(
            MenuBarPopoverSizing.acceptsMeasuredContentWidth(
                MenuBarStatusItemIdentity.popoverContentWidth + 4
            )
        )
    }

    func testFlexibleSectionHeightCapReturnsRemainingBudgetForScrollableSection() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: 520
            ),
            160
        )
    }

    func testFlexibleSectionHeightCapDoesNotExpandSectionWhenContentFits() {
        XCTAssertNil(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 420,
                flexibleSectionHeight: 120,
                availableHeight: 640
            )
        )
    }

    func testFlexibleSectionHeightCapFloorsToMinimumHeightWhenFixedChromeExceedsAvailableHeight() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 120,
                availableHeight: 400
            ),
            MenuBarPopoverSizing.minimumHeight
        )
    }

    func testFlexibleSectionHeightCapReturnsNilWithoutAvailableHeight() {
        XCTAssertNil(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 620,
                flexibleSectionHeight: 260,
                availableHeight: nil
            )
        )
    }

    func testFlexibleSectionHeightCapPrioritizesKeepingFixedChromeVisibleWhenBannerAppears() {
        XCTAssertEqual(
            MenuBarPopoverSizing.flexibleSectionHeightCap(
                totalContentHeight: 708,
                flexibleSectionHeight: 248,
                availableHeight: 520
            ),
            60
        )
    }

    func testMacOS15UsesRoomierTopAndBottomInsets() {
        XCTAssertEqual(MenuBarPopoverSizing.contentInsets(for: self.macOS14).top, 6)
        XCTAssertEqual(MenuBarPopoverSizing.contentInsets(for: self.macOS14).bottom, 6)
        XCTAssertEqual(MenuBarPopoverSizing.contentInsets(for: self.macOS15).top, 8)
        XCTAssertEqual(MenuBarPopoverSizing.contentInsets(for: self.macOS15).bottom, 8)
    }
}
