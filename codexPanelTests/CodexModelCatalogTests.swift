import XCTest

@MainActor
final class CodexModelCatalogTests: XCTestCase {
    func testGPT56ModelOptionsExposeEachTierOnce() {
        let options = MenuBarView.codexModelOptions
        XCTAssertEqual(Array(options.prefix(3)), [
            "gpt-5.6",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
        ])
        XCTAssertEqual(options.filter { $0 == "gpt-5.6" }.count, 1)
        XCTAssertEqual(options.filter { $0 == "gpt-5.6-terra" }.count, 1)
        XCTAssertEqual(options.filter { $0 == "gpt-5.6-luna" }.count, 1)
        XCTAssertFalse(options.contains("gpt-5.6-sol"))
    }

    func testGPT56SolCurrentModelIsNormalizedInCodexOptions() {
        let options = MenuBarView.codexModelSelectionOptions(currentModel: "gpt-5.6-sol")

        XCTAssertEqual(options, [
            "gpt-5.6",
            "gpt-5.6-terra",
            "gpt-5.6-luna",
            "gpt-5.5",
            "gpt-5.4",
            "gpt-5.4-mini",
        ])
        XCTAssertEqual(options.filter { $0 == "gpt-5.6" }.count, 1)
    }

    func testCurrentCodexModelDoesNotChangeCatalogOrder() {
        let options = MenuBarView.codexModelSelectionOptions(currentModel: "gpt-5.6-luna")

        XCTAssertEqual(options, MenuBarView.codexModelOptions)
    }

    func testCodexModelDisplayNamesMatchCodexPicker() {
        XCTAssertEqual(MenuBarView.codexModelOptions.map(MenuBarView.codexModelDisplayName), [
            "5.6 Sol",
            "5.6 Terra",
            "5.6 Luna",
            "5.5",
            "5.4",
            "5.4 Mini",
        ])
        XCTAssertEqual(MenuBarView.codexModelDisplayName(for: "gpt-5.6-sol"), "5.6 Sol")
    }

    func testCodexReasoningEffortOptionsMatchSelectedModelCapabilities() {
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.6"), [
            "low", "medium", "high", "xhigh", "max", "ultra",
        ])
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.6-terra"), [
            "low", "medium", "high", "xhigh", "max", "ultra",
        ])
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.6-luna"), [
            "low", "medium", "high", "xhigh", "max",
        ])
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.5"), [
            "low", "medium", "high", "xhigh",
        ])
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.4"), [
            "low", "medium", "high", "xhigh",
        ])
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-5.4-mini"), [
            "low", "medium", "high", "xhigh",
        ])
    }
}
