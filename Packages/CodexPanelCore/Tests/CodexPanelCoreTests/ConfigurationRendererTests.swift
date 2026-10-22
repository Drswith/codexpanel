import Foundation
import XCTest
@testable import CodexPanelCore

final class ConfigurationRendererTests: XCTestCase {
    func testRendersOAuthAggregateGatewayConfigurationWithoutPlatformDependencies() throws {
        let refreshAt = Date(timeIntervalSince1970: 1_790_000_000)
        let request = self.makeRequest(
            kind: .openAIOAuth,
            credentials: CodexAccountCredentials(
                accessToken: "access-token",
                refreshToken: "refresh-token",
                idToken: "id-token",
                accountID: "account-1",
                oauthClientID: "client-1",
                lastRefreshAt: refreshAt
            ),
            usageMode: .aggregateGateway
        )

        let rendered = try CodexConfigurationRenderer().render(
            request: request,
            existingConfigTOML: """
            preferred_auth_method = "chatgpt"
            model = "old-model"
            [model_providers.OpenAI]
            name = "legacy"
            """,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let authObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rendered.authJSON) as? [String: Any]
        )
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        XCTAssertEqual(authObject["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(authObject["client_id"] as? String, "client-1")
        XCTAssertEqual(
            authObject["last_refresh"] as? String,
            ISO8601DateFormatter().string(from: refreshAt)
        )
        XCTAssertEqual(tokens["account_id"] as? String, "account-1")

        let toml = String(decoding: rendered.configTOML, as: UTF8.self)
        XCTAssertTrue(toml.contains(#"model = "old-model""#))
        XCTAssertFalse(toml.contains("service_tier"))
        XCTAssertTrue(toml.contains(#"openai_base_url = "http://localhost:1456/v1""#))
        XCTAssertFalse(toml.contains("preferred_auth_method"))
        XCTAssertFalse(toml.contains("model_providers.OpenAI"))
    }


    func testRendersChatCompletionsGatewayForCompatibleProvider() throws {
        var request = self.makeRequest(
            kind: .openAICompatible,
            credentials: CodexAccountCredentials(apiKey: "provider-key")
        )
        request.provider = CodexProviderConfiguration(
            kind: .openAICompatible,
            baseURL: "https://api.example.com/v1",
            wireAPI: .chat
        )

        let rendered = try CodexConfigurationRenderer().render(
            request: request,
            existingConfigTOML: "service_tier = \"fast\"\n"
        )

        let authObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rendered.authJSON) as? [String: Any]
        )
        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, "provider-key")

        let toml = String(decoding: rendered.configTOML, as: UTF8.self)
        XCTAssertFalse(toml.contains("model ="))
        XCTAssertTrue(toml.contains(#"openai_base_url = "http://localhost:1458/v1""#))
        XCTAssertTrue(toml.contains(#"service_tier = "fast""#))
    }

    func testRejectsUnsupportedContractVersion() {
        var request = self.makeRequest(
            kind: .openAICompatible,
            credentials: CodexAccountCredentials(apiKey: "provider-key")
        )
        request.schemaVersion = 99

        XCTAssertThrowsError(
            try CodexConfigurationRenderer().render(
                request: request,
                existingConfigTOML: ""
            )
        ) { error in
            XCTAssertEqual(
                error as? CodexConfigurationSyncError,
                .unsupportedSchemaVersion
            )
        }
    }

    func testContractRoundTripsThroughJSON() throws {
        let request = self.makeRequest(
            kind: .openRouter,
            credentials: CodexAccountCredentials(apiKey: "openrouter-key")
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(CodexConfigurationSyncRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.schemaVersion, 2)
    }

    func testAllProviderModesPreserveCodexOwnedSettingsAndProfiles() throws {
        let existing = """
        # Codex owns these values, including future options.
        model = "user-selected-model" # keep comment
        review_model = "review-only-model"
        model_reasoning_effort = "future-effort"
        model_reasoning_summary = "detailed"
        service_tier = "future-tier"
        model_catalog_json = "/tmp/user-models.json"
        # Whitespace inside user strings must survive routing updates.
        user_note = '''first


        last'''
        [profiles.work]
        model = "profile-model"
        model_reasoning_effort = "profile-effort"
        service_tier = "profile-tier"
        """
        for kind in [CodexProviderKind.openAIOAuth, .openAICompatible, .openRouter] {
            for mode in [CodexAccountUsageMode.direct, .aggregateGateway] {
                for wire in [CodexWireAPI.responses, .chat] {
                    var request = self.makeRequest(kind: kind, credentials: CodexAccountCredentials(
                        accessToken: "access", refreshToken: "refresh", idToken: "id", accountID: "account", apiKey: "key"
                    ), usageMode: mode)
                    request.provider.wireAPI = wire
                    let output = try CodexConfigurationRenderer().render(request: request, existingConfigTOML: existing)
                    let toml = String(decoding: output.configTOML, as: UTF8.self)
                    XCTAssertTrue(toml.contains(existing), "\(kind) / \(mode) / \(wire): \(toml)")
                    let empty = try CodexConfigurationRenderer().render(request: request, existingConfigTOML: "")
                    let emptyTOML = String(decoding: empty.configTOML, as: UTF8.self)
                    for key in ["model", "review_model", "model_reasoning_effort", "service_tier", "model_catalog_json"] {
                        XCTAssertFalse(emptyTOML.contains("\(key) ="), emptyTOML)
                    }
                }
            }
        }
    }

    func testLegacyContractIsRejectedBeforeRendering() {
        var request = self.makeRequest(kind: .openAICompatible, credentials: CodexAccountCredentials(apiKey: "key"))
        request.schemaVersion = 1
        XCTAssertThrowsError(try CodexConfigurationRenderer().render(request: request, existingConfigTOML: "")) {
            XCTAssertEqual($0 as? CodexConfigurationSyncError, .unsupportedSchemaVersion)
        }
    }

    private func makeRequest(
        kind: CodexProviderKind,
        credentials: CodexAccountCredentials,
        usageMode: CodexAccountUsageMode = .direct
    ) -> CodexConfigurationSyncRequest {
        CodexConfigurationSyncRequest(
            provider: CodexProviderConfiguration(
                kind: kind,
                baseURL: "https://api.example.com/v1"
            ),
            credentials: credentials,
            accountUsageMode: usageMode,
            network: CodexNetworkConfiguration(
                openAIAccountGatewayBaseURL: "http://localhost:1456/v1",
                openRouterGatewayBaseURL: "http://localhost:1457/v1",
                chatCompletionsGatewayBaseURL: "http://localhost:1458/v1",
                openRouterGatewayAPIKey: "codexpanel-openrouter-gateway"
            )
        )
    }
}
