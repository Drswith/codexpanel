import Foundation

/// Core 与宿主层之间的首版同步契约。未来若切换为 sidecar，字段应通过版本迁移演进，
/// 而不是让 UI 直接依赖 Core 内部实现。
public struct CodexConfigurationSyncRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var global: CodexGlobalConfiguration
    public var provider: CodexProviderConfiguration
    public var credentials: CodexAccountCredentials
    public var accountUsageMode: CodexAccountUsageMode
    public var network: CodexNetworkConfiguration

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        global: CodexGlobalConfiguration,
        provider: CodexProviderConfiguration,
        credentials: CodexAccountCredentials,
        accountUsageMode: CodexAccountUsageMode,
        network: CodexNetworkConfiguration
    ) {
        self.schemaVersion = schemaVersion
        self.global = global
        self.provider = provider
        self.credentials = credentials
        self.accountUsageMode = accountUsageMode
        self.network = network
    }
}

public struct CodexGlobalConfiguration: Codable, Equatable, Sendable {
    public var defaultModel: String
    public var reviewModel: String
    public var reasoningEffort: String
    public var serviceTier: String

    public init(
        defaultModel: String,
        reviewModel: String,
        reasoningEffort: String,
        serviceTier: String
    ) {
        self.defaultModel = defaultModel
        self.reviewModel = reviewModel
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
    }
}

public struct CodexProviderConfiguration: Codable, Equatable, Sendable {
    public var kind: CodexProviderKind
    public var baseURL: String?
    public var modelID: String?
    public var wireAPI: CodexWireAPI

    public init(
        kind: CodexProviderKind,
        baseURL: String? = nil,
        modelID: String? = nil,
        wireAPI: CodexWireAPI = .responses
    ) {
        self.kind = kind
        self.baseURL = baseURL
        self.modelID = modelID
        self.wireAPI = wireAPI
    }
}

public enum CodexProviderKind: String, Codable, Equatable, Sendable {
    case openAIOAuth = "openai_oauth"
    case openAICompatible = "openai_compatible"
    case openRouter = "openrouter"
}

public enum CodexWireAPI: String, Codable, Equatable, Sendable {
    case responses
    case chat
}

public enum CodexAccountUsageMode: String, Codable, Equatable, Sendable {
    case direct
    case aggregateGateway = "aggregate_gateway"
}

public struct CodexAccountCredentials: Codable, Equatable, Sendable {
    public var accessToken: String?
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?
    public var apiKey: String?
    public var oauthClientID: String?
    public var lastRefreshAt: Date?

    public init(
        accessToken: String? = nil,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        apiKey: String? = nil,
        oauthClientID: String? = nil,
        lastRefreshAt: Date? = nil
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.apiKey = apiKey
        self.oauthClientID = oauthClientID
        self.lastRefreshAt = lastRefreshAt
    }
}

public struct CodexNetworkConfiguration: Codable, Equatable, Sendable {
    public var openAIAccountGatewayBaseURL: String
    public var openRouterGatewayBaseURL: String
    public var chatCompletionsGatewayBaseURL: String
    public var openRouterGatewayAPIKey: String

    public init(
        openAIAccountGatewayBaseURL: String,
        openRouterGatewayBaseURL: String,
        chatCompletionsGatewayBaseURL: String,
        openRouterGatewayAPIKey: String
    ) {
        self.openAIAccountGatewayBaseURL = openAIAccountGatewayBaseURL
        self.openRouterGatewayBaseURL = openRouterGatewayBaseURL
        self.chatCompletionsGatewayBaseURL = chatCompletionsGatewayBaseURL
        self.openRouterGatewayAPIKey = openRouterGatewayAPIKey
    }
}

public struct CodexRenderedConfiguration: Equatable, Sendable {
    public var authJSON: Data
    public var configTOML: Data

    public init(authJSON: Data, configTOML: Data) {
        self.authJSON = authJSON
        self.configTOML = configTOML
    }
}

public enum CodexConfigurationSyncError: String, Codable, Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion = "unsupported_schema_version"
    case missingActiveProvider = "missing_active_provider"
    case missingActiveAccount = "missing_active_account"
    case missingOAuthTokens = "missing_oauth_tokens"
    case missingAPIKey = "missing_api_key"
    case missingOpenRouterModel = "missing_openrouter_model"

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion: return "Core 同步契约版本不受支持"
        case .missingActiveProvider: return "未找到当前激活的 provider"
        case .missingActiveAccount: return "未找到当前激活的账号"
        case .missingOAuthTokens: return "当前 OAuth 账号缺少必要 token"
        case .missingAPIKey: return "当前 API Key 账号缺少密钥"
        case .missingOpenRouterModel: return "OpenRouter 需要先选择或输入模型 ID"
        }
    }
}
