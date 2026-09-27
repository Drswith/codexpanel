import Foundation
import XCTest

final class CodexServiceTierCatalogTests: CodexPanelTestCase {
    func testParseReadsPerModelServiceTiersFromCodexModelsCache() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.6-sol", tiers: [("priority", "Fast")]),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
                Self.model("gpt-5.5", tiers: []),
            ]
        ))

        XCTAssertEqual(catalog.models.map(\.slug), ["gpt-5.6-sol", "gpt-6-astra", "gpt-5.5"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "gpt-5.6-sol"), ["standard", "fast"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "GPT-6-Astra "), ["standard", "fast", "ultrafast"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "gpt-5.5"), ["standard"])
        XCTAssertNil(catalog.serviceTierOptions(for: "gpt-unknown"))
        XCTAssertEqual(catalog.fetchedAt, ISO8601Parsing.parse("2026-09-26T04:14:16Z"))
    }

    func testParseSkipsMalformedModelEntriesWithoutFailingWholeCatalog() throws {
        let json = """
        {
          "fetched_at": "2026-09-26T04:14:16.319744Z",
          "models": [
            {"slug": "gpt-5.6-sol", "service_tiers": [{"id": "priority", "name": "Fast", "description": ""}]},
            {"display_name": "missing slug"},
            "not-an-object"
          ]
        }
        """
        let catalog = try CodexServiceTierCatalog.parse(Data(json.utf8))

        XCTAssertEqual(catalog.models.map(\.slug), ["gpt-5.6-sol"])
    }

    func testLoadReturnsNilWhenCacheIsMissingOrCorrupt() throws {
        XCTAssertNil(CodexServiceTierCatalog.load())

        try CodexPaths.ensureDirectories()
        try Data("{not json".utf8).write(to: CodexPaths.modelsCacheURL)
        XCTAssertNil(CodexServiceTierCatalog.load())
    }

    func testGlobalSettingsFallBackToBuiltinOptionsWithoutCatalog() {
        XCTAssertEqual(
            CodexPanelGlobalSettings.serviceTierOptions(for: "gpt-5.6-sol", catalog: nil),
            ["standard", "fast"]
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings.compatibleServiceTier("ultrafast", for: "gpt-5.6-sol", catalog: nil),
            "standard"
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings.compatibleServiceTier("flex", for: "gpt-5.6-sol", catalog: nil),
            "standard"
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings.compatibleServiceTier("priority", for: "gpt-5.6-sol", catalog: nil),
            "fast"
        )
    }

    func testGlobalSettingsFollowCatalogWhenModelDropsOrGainsTiers() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.5", tiers: []),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
            ]
        ))

        XCTAssertEqual(
            CodexPanelGlobalSettings.serviceTierOptions(for: "gpt-5.5", catalog: catalog),
            ["standard"]
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings.compatibleServiceTier("fast", for: "gpt-5.5", catalog: catalog),
            "standard"
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings.compatibleServiceTier("ultrafast", for: "gpt-6-astra", catalog: catalog),
            "ultrafast"
        )
        XCTAssertTrue(CodexPanelGlobalSettings.supportsServiceTier("ultrafast", for: "gpt-6-astra", catalog: catalog))
        XCTAssertFalse(CodexPanelGlobalSettings.supportsServiceTier("ultrafast", for: "gpt-5.5", catalog: catalog))
    }

    func testCodexConfigServiceTierWritesOnlySupportedTiers() throws {
        let catalog = try CodexServiceTierCatalog.parse(Self.fixture(
            models: [
                Self.model("gpt-5.5", tiers: []),
                Self.model("gpt-6-astra", tiers: [("priority", "Fast"), ("ultrafast", "Ultrafast")]),
                Self.model("gpt-defaulted", tiers: [("priority", "Fast")], defaultTier: "priority"),
            ]
        ))

        XCTAssertNil(
            CodexPanelGlobalSettings(serviceTier: "standard").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog)
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings(serviceTier: "fast").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog),
            "fast"
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings(serviceTier: "ultrafast").codexConfigServiceTier(for: "gpt-6-astra", catalog: catalog),
            "ultrafast"
        )
        XCTAssertNil(
            CodexPanelGlobalSettings(serviceTier: "fast").codexConfigServiceTier(for: "gpt-5.5", catalog: catalog),
            "模型不再支持 fast 时应回落为标准路由并删键"
        )
        XCTAssertEqual(
            CodexPanelGlobalSettings(serviceTier: "standard").codexConfigServiceTier(for: "gpt-defaulted", catalog: catalog),
            "default",
            "目录声明了默认档位时，标准路由需要显式写 default 哨兵值"
        )
        XCTAssertNil(
            CodexPanelGlobalSettings(serviceTier: "flex").codexConfigServiceTier(for: "gpt-6-astra", catalog: nil)
        )
    }

    func testNormalizedServiceTierAcceptsCatalogIdentifiersAndRejectsGarbage() {
        XCTAssertEqual(CodexPanelGlobalSettings.normalizedServiceTier(" Flex "), "standard")
        XCTAssertEqual(CodexPanelGlobalSettings.normalizedServiceTier("default"), "standard")
        XCTAssertEqual(CodexPanelGlobalSettings.normalizedServiceTier("priority"), "fast")
        XCTAssertEqual(CodexPanelGlobalSettings.normalizedServiceTier("ultrafast"), "ultrafast")
        XCTAssertEqual(CodexPanelGlobalSettings.normalizedServiceTier("tier_2-beta"), "tier_2-beta")
        XCTAssertNil(CodexPanelGlobalSettings.normalizedServiceTier(""))
        XCTAssertNil(CodexPanelGlobalSettings.normalizedServiceTier("fast mode"))
        XCTAssertNil(CodexPanelGlobalSettings.normalizedServiceTier("\"fast\""))
        XCTAssertNil(CodexPanelGlobalSettings.normalizedServiceTier("-fast"))
    }

    static func model(
        _ slug: String,
        tiers: [(String, String)],
        defaultTier: String? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "slug": slug,
            "display_name": slug,
            "supported_reasoning_levels": [["effort": "medium", "description": ""]],
            "additional_speed_tiers": tiers.isEmpty ? [] : ["fast"],
            "service_tiers": tiers.map { ["id": $0.0, "name": $0.1, "description": "\($0.1) tier"] },
        ]
        entry["default_service_tier"] = defaultTier ?? NSNull()
        return entry
    }

    static func fixture(models: [[String: Any]]) -> Data {
        let payload: [String: Any] = [
            "fetched_at": "2026-09-26T04:14:16.000000Z",
            "etag": "W/\"fixture\"",
            "client_version": "0.158.0",
            "models": models,
        ]
        return try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    static func writeFixture(models: [[String: Any]]) throws {
        try CodexPaths.ensureDirectories()
        try Self.fixture(models: models).write(to: CodexPaths.modelsCacheURL)
    }
}
