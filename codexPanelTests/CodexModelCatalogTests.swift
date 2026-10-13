import Foundation
import XCTest

@MainActor
final class CodexModelCatalogTests: XCTestCase {
    func testFallbackIncludesGPT6AndPreservesExactCurrentID() {
        let options = MenuBarView.codexModelSelectionOptions(currentModel: "gpt-5.6-sol")
        XCTAssertEqual(Array(options.prefix(4)), ["gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"])
        XCTAssertEqual(options.last, "gpt-5.6-sol")
        XCTAssertEqual(options.filter { $0 == "gpt-5.6-sol" }.count, 1)
        XCTAssertEqual(MenuBarView.codexModelSelectionOptions(currentModel: "gpt-6-luna"), MenuBarView.codexModelOptions)
    }

    func testCacheDrivesNamesVisibilityAndCapabilitiesForUnknownFutureModel() throws {
        let data = Data(#"{"models":[{"slug":"future-model","display_name":"Future Model","visibility":"list","default_reasoning_level":"balanced","supported_reasoning_levels":[{"effort":"balanced"},{"effort":"deep"}],"service_tiers":[{"id":"priority","name":"Fast"},{"id":"ultrafast","name":"Ultrafast"}]},{"slug":"internal-model","visibility":"hide"}]}"#.utf8)
        let catalog = try CodexModelCatalog.parse(data)
        XCTAssertEqual(MenuBarView.codexModelSelectionOptions(currentModel: "custom-model", catalog: catalog), ["future-model", "custom-model"])
        XCTAssertEqual(catalog.selectionOptions(currentModel: "internal-model"), ["future-model", "internal-model"])
        XCTAssertEqual(MenuBarView.codexModelDisplayName(for: "future-model", catalog: catalog), "Future Model")
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "future-model", catalog: catalog), ["balanced", "deep"])
        XCTAssertEqual(CodexPanelGlobalSettings.reasoningEffortOptions(for: "future-model", currentValue: "legacy", catalog: catalog), ["balanced", "deep", "legacy"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "future-model"), ["standard", "fast", "ultrafast"])
        XCTAssertFalse(CodexPanelGlobalSettings.supportsReasoningEffort("ultra", for: "future-model", catalog: catalog))
        XCTAssertEqual(CodexPanelGlobalSettings.compatibleReasoningEffort("ultra", for: "future-model", catalog: catalog), "balanced")
    }

    func testAliasesOnlyAffectLookupAndNeverRewriteSelectedModel() throws {
        let catalog = try CodexModelCatalog.parse(Data(#"{"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6 Sol","service_tiers":[]}]}"#.utf8))
        XCTAssertEqual(catalog.selectionOptions(currentModel: "gpt-5.6"), ["gpt-5.6-sol", "gpt-5.6"])
        XCTAssertEqual(catalog.displayName(for: "gpt-5.6"), "GPT-5.6 Sol")
        XCTAssertEqual(catalog.serviceTierOptions(for: "gpt-5.6"), ["standard"])
    }

    func testEmptyAndPartialCacheUseFallbacks() throws {
        let empty = try CodexModelCatalog.parse(Data(#"{"models":[]}"#.utf8))
        XCTAssertEqual(empty.selectionOptions(currentModel: "custom"), CodexModelCatalog.fallbackModelIDs + ["custom"])
        let partial = try CodexModelCatalog.parse(Data(#"{"models":[{"slug":"gpt-6-luna"}]}"#.utf8))
        XCTAssertNil(partial.serviceTierOptions(for: "gpt-6-luna"))
        XCTAssertEqual(MenuBarView.codexReasoningEffortOptions(for: "gpt-6-luna", catalog: partial), ["low", "medium", "high", "xhigh", "max"])
        XCTAssertThrowsError(try CodexModelCatalog.parse(Data(#"{"models":"invalid"}"#.utf8)))
    }

    func testModelListFieldsAndServiceTierMerge() throws {
        let page = try CodexModelListSession.parsePage([
            "data": [["id": "entry-id", "model": "new-model", "displayName": "New", "hidden": false,
                      "supportedReasoningEfforts": [["reasoningEffort": "max"]], "defaultReasoningEffort": "max"],
                     ["model": "hidden-model", "hidden": true]],
            "nextCursor": "page-2",
        ])
        XCTAssertEqual(page.nextCursor, "page-2")
        XCTAssertEqual(page.models.map(\.slug), ["new-model", "hidden-model"])
        let rpc = CodexModelCatalog(models: page.models, fetchedAt: Date())
        let cache = try CodexModelCatalog.parse(Data(#"{"models":[{"slug":"new-model","service_tiers":[{"id":"priority"}],"supported_reasoning_levels":[{"effort":"low"}]}]}"#.utf8))
        let merged = rpc.mergingServiceTiers(from: cache)
        XCTAssertEqual(merged.reasoningEffortOptions(for: "new-model"), ["max"])
        XCTAssertEqual(merged.serviceTierOptions(for: "new-model"), ["standard", "fast"])
        XCTAssertEqual(merged.selectionOptions(currentModel: "new-model"), ["new-model"])
    }
}
