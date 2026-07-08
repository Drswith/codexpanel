import Foundation
import XCTest

final class CodexSyncServiceTests: CodexPanelTestCase {
    func testSynchronizeRestoresPreviousFilesWhenConfigWriteFails() throws {
        try CodexPaths.ensureDirectories()

        let originalAuth = Data(#"{"auth_mode":"chatgpt","tokens":{"account_id":"old"}}"#.utf8)
        let originalToml = Data("model = \"gpt-5.5-mini\"\n".utf8)
        try CodexPaths.writeSecureFile(originalAuth, to: CodexPaths.authURL)
        try CodexPaths.writeSecureFile(originalToml, to: CodexPaths.configTomlURL)

        let account = CodexPanelProviderAccount(
            id: "acct_new",
            kind: .oauthTokens,
            label: "new@example.com",
            email: "new@example.com",
            openAIAccountId: "acct_new",
            accessToken: "access-new",
            refreshToken: "refresh-new",
            idToken: "id-new"
        )
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexPanelConfig(
            active: CodexPanelActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        var configWriteAttempts = 0
        let service = CodexSyncService(
            writeSecureFile: { data, url in
                if url == CodexPaths.configTomlURL {
                    configWriteAttempts += 1
                    if configWriteAttempts == 1 {
                        throw SyncFailure.configWriteFailed
                    }
                }
                try CodexPaths.writeSecureFile(data, to: url)
            }
        )

        XCTAssertThrowsError(try service.synchronize(config: config)) { error in
            XCTAssertEqual(error as? SyncFailure, .configWriteFailed)
        }

        XCTAssertEqual(try Data(contentsOf: CodexPaths.authURL), originalAuth)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.configTomlURL), originalToml)
    }

    func testSynchronizePreservesChatGPTAuthAndServiceTierWhenAggregateModeIsEnabled() throws {
        try CodexPaths.ensureDirectories()
        try CodexPaths.writeSecureFile(
            Data(
                """
                service_tier = "fast"
                preferred_auth_method = "chatgpt"
                model = "gpt-5.5-mini"
                """.utf8
            ),
            to: CodexPaths.configTomlURL
        )

        let account = CodexPanelProviderAccount(
            id: "acct_pool",
            kind: .oauthTokens,
            label: "pool@example.com",
            email: "pool@example.com",
            openAIAccountId: "acct_pool",
            accessToken: "access-pool",
            refreshToken: "refresh-pool",
            idToken: "id-pool"
        )
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexPanelConfig(
            active: CodexPanelActiveSelection(providerId: provider.id, accountId: account.id),
            openAI: CodexPanelOpenAISettings(accountUsageMode: .aggregateGateway),
            providers: [provider]
        )

        try CodexSyncService(networkConfiguration: self.releaseNetworkConfiguration()).synchronize(config: config)

        let authText = try String(contentsOf: CodexPaths.authURL, encoding: .utf8)
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertTrue(authText.contains(#""auth_mode" : "chatgpt""#))
        XCTAssertTrue(authText.contains("access-pool"))
        XCTAssertFalse(authText.contains("codexpanel-local-gateway"))
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1456/v1""#))
        XCTAssertTrue(tomlText.contains(#"service_tier = "fast""#))
        XCTAssertFalse(tomlText.contains("preferred_auth_method"))
    }

    func testSynchronizeWritesOAuthLifecycleMetadataToAuthJSON() throws {
        let tokenLastRefreshAt = Date(timeIntervalSince1970: 1_790_000_000)
        let account = CodexPanelProviderAccount(
            id: "acct_sync_metadata",
            kind: .oauthTokens,
            label: "sync@example.com",
            email: "sync@example.com",
            openAIAccountId: "acct_sync_metadata",
            accessToken: "access-sync",
            refreshToken: "refresh-sync",
            idToken: "id-sync",
            expiresAt: Date(timeIntervalSince1970: 1_790_003_600),
            oauthClientID: "app_sync_client",
            tokenLastRefreshAt: tokenLastRefreshAt,
            lastRefresh: tokenLastRefreshAt
        )
        let provider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexPanelConfig(
            active: CodexPanelActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        try CodexSyncService(networkConfiguration: self.releaseNetworkConfiguration()).synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tokens = try XCTUnwrap(authObject["tokens"] as? [String: Any])
        let formatter = ISO8601DateFormatter()

        XCTAssertEqual(authObject["client_id"] as? String, "app_sync_client")
        XCTAssertEqual(authObject["last_refresh"] as? String, formatter.string(from: tokenLastRefreshAt))
        XCTAssertEqual(tokens["access_token"] as? String, "access-sync")
        XCTAssertEqual(tokens["refresh_token"] as? String, "refresh-sync")
        XCTAssertEqual(tokens["account_id"] as? String, "acct_sync_metadata")
    }

    func testSynchronizeWritesOpenRouterGatewayConfigAndProviderModel() throws {
        let account = CodexPanelProviderAccount(
            id: "acct_openrouter",
            kind: .apiKey,
            label: "OpenRouter Primary",
            apiKey: "sk-or-v1-primary"
        )
        let provider = CodexPanelProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            enabled: true,
            selectedModelID: "anthropic/claude-3.7-sonnet",
            activeAccountId: account.id,
            accounts: [account]
        )
        let config = CodexPanelConfig(
            global: CodexPanelGlobalSettings(
                defaultModel: "gpt-5.5",
                reviewModel: "gpt-5.5",
                reasoningEffort: "high"
            ),
            active: CodexPanelActiveSelection(providerId: provider.id, accountId: account.id),
            providers: [provider]
        )

        try CodexSyncService(networkConfiguration: self.releaseNetworkConfiguration()).synchronize(config: config)

        let authObject = try self.readAuthJSON()
        let tomlText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)

        XCTAssertEqual(authObject["OPENAI_API_KEY"] as? String, OpenRouterGatewayConfiguration.apiKey)
        XCTAssertTrue(tomlText.contains(#"openai_base_url = "http://localhost:1457/v1""#))
        XCTAssertTrue(tomlText.contains(#"model = "anthropic/claude-3.7-sonnet""#))
        XCTAssertTrue(tomlText.contains(#"review_model = "anthropic/claude-3.7-sonnet""#))
    }

    func testSynchronizeWritesDebugGatewayBaseURLsWhenUsingDebugNetworkProfile() throws {
        let openAIAccount = CodexPanelProviderAccount(
            id: "acct_pool",
            kind: .oauthTokens,
            label: "pool@example.com",
            email: "pool@example.com",
            openAIAccountId: "acct_pool",
            accessToken: "access-pool",
            refreshToken: "refresh-pool",
            idToken: "id-pool"
        )
        let openAIProvider = CodexPanelProvider(
            id: "openai-oauth",
            kind: .openAIOAuth,
            label: "OpenAI",
            activeAccountId: openAIAccount.id,
            accounts: [openAIAccount]
        )
        let openAIConfig = CodexPanelConfig(
            active: CodexPanelActiveSelection(providerId: openAIProvider.id, accountId: openAIAccount.id),
            openAI: CodexPanelOpenAISettings(accountUsageMode: .aggregateGateway),
            providers: [openAIProvider]
        )

        try CodexSyncService(networkConfiguration: self.debugNetworkConfiguration()).synchronize(config: openAIConfig)

        let openAITOMLText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertTrue(openAITOMLText.contains(#"openai_base_url = "http://localhost:1556/v1""#))

        let openRouterAccount = CodexPanelProviderAccount(
            id: "acct_openrouter",
            kind: .apiKey,
            label: "OpenRouter Primary",
            apiKey: "sk-or-v1-primary"
        )
        let openRouterProvider = CodexPanelProvider(
            id: "openrouter",
            kind: .openRouter,
            label: "OpenRouter",
            selectedModelID: "anthropic/claude-3.7-sonnet",
            activeAccountId: openRouterAccount.id,
            accounts: [openRouterAccount]
        )
        let openRouterConfig = CodexPanelConfig(
            active: CodexPanelActiveSelection(providerId: openRouterProvider.id, accountId: openRouterAccount.id),
            providers: [openRouterProvider]
        )

        try CodexSyncService(networkConfiguration: self.debugNetworkConfiguration()).synchronize(config: openRouterConfig)

        let openRouterTOMLText = try String(contentsOf: CodexPaths.configTomlURL, encoding: .utf8)
        XCTAssertTrue(openRouterTOMLText.contains(#"openai_base_url = "http://localhost:1557/v1""#))
    }

    private enum SyncFailure: Error, Equatable {
        case configWriteFailed
    }

    private func debugNetworkConfiguration() -> CodexPanelRuntimeNetworkConfiguration {
        CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [:],
            defaultHome: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        ).network
    }

    private func releaseNetworkConfiguration() -> CodexPanelRuntimeNetworkConfiguration {
        CodexPanelRuntimeProfile.resolve(
            channel: .release,
            environment: [:],
            defaultHome: URL(fileURLWithPath: "/Users/example", isDirectory: true)
        ).network
    }
}
