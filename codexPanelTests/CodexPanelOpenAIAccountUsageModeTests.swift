import XCTest

final class CodexPanelOpenAIAccountUsageModeTests: XCTestCase {
    private var originalLanguageOverride: Bool?

    override func setUp() {
        super.setUp()
        self.originalLanguageOverride = L.languageOverride
    }

    override func tearDown() {
        L.languageOverride = self.originalLanguageOverride
        super.tearDown()
    }

    func testMenuToggleTitlesUseRequestedChineseCopy() {
        L.languageOverride = true

        XCTAssertEqual(CodexPanelOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "切换")
        XCTAssertEqual(CodexPanelOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "聚合")
    }

    func testMenuToggleTitlesUseCompactEnglishCopy() {
        L.languageOverride = false

        XCTAssertEqual(CodexPanelOpenAIAccountUsageMode.switchAccount.menuToggleTitle, "Switch")
        XCTAssertEqual(CodexPanelOpenAIAccountUsageMode.aggregateGateway.menuToggleTitle, "Aggregate")
    }

    func testUsageModeOrderKeepsSwitchOnTheLeftAndAggregateOnTheRight() {
        XCTAssertEqual(
            CodexPanelOpenAIAccountUsageMode.allCases,
            [.switchAccount, .aggregateGateway]
        )
    }
}
