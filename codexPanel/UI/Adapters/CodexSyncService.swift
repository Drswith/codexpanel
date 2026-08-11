import CodexPanelCore
import Foundation

protocol CodexSynchronizing {
    func synchronize(config: CodexPanelConfig) throws
}

typealias CodexSyncError = CodexConfigurationSyncError

/// macOS App adapter：只负责把 UI 模型、运行 profile 与路径映射到 Core 契约。
struct CodexSyncService: CodexSynchronizing {
    private let synchronizer: CodexConfigurationSynchronizer
    private let networkConfiguration: CodexPanelRuntimeNetworkConfiguration

    init(
        networkConfiguration: CodexPanelRuntimeNetworkConfiguration = CodexPanelRuntimeProfile.current.network,
        ensureDirectories: @escaping () throws -> Void = { try CodexPaths.ensureDirectories() },
        backupFileIfPresent: @escaping (URL, URL) throws -> Void = { source, destination in
            try CodexPaths.backupFileIfPresent(from: source, to: destination)
        },
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readString: @escaping (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        fileExists: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        removeFileIfPresent: @escaping (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        }
    ) {
        let paths = CodexConfigurationPaths(
            authURL: CodexPaths.authURL,
            configTOMLURL: CodexPaths.configTomlURL,
            authBackupURL: CodexPaths.authBackupURL,
            configBackupURL: CodexPaths.configBackupURL
        )
        let fileSystem = CodexConfigurationFileSystem(
            prepare: ensureDirectories,
            readData: readData,
            readString: readString,
            backupFileIfPresent: backupFileIfPresent,
            writeSecureFile: writeSecureFile,
            fileExists: fileExists,
            removeFileIfPresent: removeFileIfPresent
        )
        self.synchronizer = CodexConfigurationSynchronizer(
            paths: paths,
            fileSystem: fileSystem
        )
        self.networkConfiguration = networkConfiguration
    }

    func synchronize(config: CodexPanelConfig) throws {
        try self.synchronizer.synchronize(self.makeRequest(config: config))
    }

    private func makeRequest(config: CodexPanelConfig) throws -> CodexConfigurationSyncRequest {
        guard let provider = config.activeProvider() else {
            throw CodexSyncError.missingActiveProvider
        }
        guard let account = config.activeAccount() else {
            throw CodexSyncError.missingActiveAccount
        }

        let providerKind: CodexProviderKind
        let modelID: String?
        switch provider.kind {
        case .openAIOAuth:
            providerKind = .openAIOAuth
            modelID = nil
        case .openAICompatible:
            providerKind = .openAICompatible
            modelID = provider.compatibleEffectiveModelID
        case .openRouter:
            providerKind = .openRouter
            modelID = provider.openRouterEffectiveModelID
        }

        return CodexConfigurationSyncRequest(
            global: CodexGlobalConfiguration(
                defaultModel: config.global.defaultModel,
                reviewModel: config.global.reviewModel,
                reasoningEffort: config.global.reasoningEffort,
                serviceTier: config.global.serviceTier
            ),
            provider: CodexProviderConfiguration(
                kind: providerKind,
                baseURL: provider.baseURL,
                modelID: modelID,
                wireAPI: provider.wireAPI == .chat ? .chat : .responses
            ),
            credentials: CodexAccountCredentials(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                idToken: account.idToken,
                accountID: account.openAIAccountId,
                apiKey: account.apiKey,
                oauthClientID: account.oauthClientID,
                lastRefreshAt: account.tokenLastRefreshAt ?? account.lastRefresh
            ),
            accountUsageMode: config.openAI.accountUsageMode == .aggregateGateway
                ? .aggregateGateway
                : .direct,
            network: CodexNetworkConfiguration(
                openAIAccountGatewayBaseURL: self.networkConfiguration.openAIAccountGatewayBaseURLString,
                openRouterGatewayBaseURL: self.networkConfiguration.openRouterGatewayBaseURLString,
                chatCompletionsGatewayBaseURL: self.networkConfiguration.chatCompletionsGatewayBaseURLString,
                openRouterGatewayAPIKey: OpenRouterGatewayConfiguration.apiKey
            )
        )
    }
}
