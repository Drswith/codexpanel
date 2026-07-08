import Foundation
import XCTest

final class CodexPanelProviderWireAPITests: XCTestCase {
    func testLegacyCompatibleProviderDecodesWithResponsesWireDefault() throws {
        let json = """
        {
            "id": "legacy",
            "kind": "openai_compatible",
            "label": "Legacy",
            "enabled": true,
            "baseURL": "https://api.legacy.invalid/v1",
            "accounts": []
        }
        """
        let provider = try JSONDecoder().decode(CodexPanelProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.wireAPI, .responses)
        XCTAssertFalse(provider.usesChatCompletionsGateway)
        XCTAssertNil(provider.presetID)
    }

    func testChatWireProviderRoundTripsThroughCodable() throws {
        let account = CodexPanelProviderAccount(id: "a", kind: .apiKey, label: "Primary", apiKey: "sk")
        let provider = CodexPanelProvider(
            id: "deepseek",
            kind: .openAICompatible,
            label: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            wireAPI: .chat,
            presetID: "deepseek",
            defaultModel: "deepseek-chat",
            selectedModelID: "deepseek-chat",
            activeAccountId: account.id,
            accounts: [account]
        )

        let data = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(CodexPanelProvider.self, from: data)

        XCTAssertEqual(decoded.wireAPI, .chat)
        XCTAssertEqual(decoded.presetID, "deepseek")
        XCTAssertTrue(decoded.usesChatCompletionsGateway)
        let selection = try XCTUnwrap(decoded.chatCompletionsServiceableSelection)
        XCTAssertEqual(selection.modelID, "deepseek-chat")
        XCTAssertEqual(selection.baseURL, "https://api.deepseek.com/v1")
    }

    func testOAuthProviderForcesResponsesWireRegardlessOfStoredValue() throws {
        let json = """
        {
            "id": "openai",
            "kind": "openai_oauth",
            "label": "OpenAI",
            "wireAPI": "chat",
            "accounts": []
        }
        """
        let provider = try JSONDecoder().decode(CodexPanelProvider.self, from: Data(json.utf8))
        XCTAssertEqual(provider.wireAPI, .responses)
    }

    func testPresetCatalogResolvesQuirks() {
        XCTAssertNotNil(CodexPanelProviderPresetCatalog.preset(id: "deepseek"))
        let openRouter = CodexPanelProviderPresetCatalog.preset(id: "openrouter")
        XCTAssertEqual(openRouter?.kind, .openRouter)
        XCTAssertEqual(openRouter?.group, .foreign)
        let glmQuirks = CodexPanelProviderPresetCatalog.quirks(forPresetID: "zhipu-glm")
        XCTAssertTrue(glmQuirks.toolChoiceDowngradeToAuto)
        let standard = CodexPanelProviderPresetCatalog.quirks(forPresetID: nil)
        XCTAssertEqual(standard.maxTokensField, "max_tokens")
    }
}
