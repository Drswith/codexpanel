import XCTest

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
}
