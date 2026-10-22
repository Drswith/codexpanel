import Foundation

/// 不依赖 AppKit/SwiftUI 或宿主路径的配置渲染器。
public struct CodexConfigurationRenderer: Sendable {
    public init() {}

    public func render(
        request: CodexConfigurationSyncRequest,
        existingConfigTOML: String,
        now: Date = Date()
    ) throws -> CodexRenderedConfiguration {
        guard request.schemaVersion == CodexConfigurationSyncRequest.currentSchemaVersion else {
            throw CodexConfigurationSyncError.unsupportedSchemaVersion
        }

        let authJSON = try self.renderAuthJSON(request: request, now: now)
        let configTOML = self.renderConfigTOML(
            request: request,
            existingText: existingConfigTOML
        )
        return CodexRenderedConfiguration(
            authJSON: authJSON,
            configTOML: Data(configTOML.utf8)
        )
    }

    private func renderAuthJSON(
        request: CodexConfigurationSyncRequest,
        now: Date
    ) throws -> Data {
        let credentials = request.credentials
        let object: [String: Any]

        switch request.provider.kind {
        case .openAIOAuth:
            guard let accessToken = credentials.accessToken,
                  let refreshToken = credentials.refreshToken,
                  let idToken = credentials.idToken,
                  let accountID = credentials.accountID else {
                throw CodexConfigurationSyncError.missingOAuthTokens
            }

            var authObject: [String: Any] = [
                "auth_mode": "chatgpt",
                "OPENAI_API_KEY": NSNull(),
                "last_refresh": ISO8601DateFormatter().string(from: credentials.lastRefreshAt ?? now),
                "tokens": [
                    "access_token": accessToken,
                    "refresh_token": refreshToken,
                    "id_token": idToken,
                    "account_id": accountID,
                ],
            ]
            if let clientID = credentials.oauthClientID, clientID.isEmpty == false {
                authObject["client_id"] = clientID
            }
            object = authObject

        case .openAICompatible:
            guard let apiKey = credentials.apiKey, apiKey.isEmpty == false else {
                throw CodexConfigurationSyncError.missingAPIKey
            }
            object = ["OPENAI_API_KEY": apiKey]

        case .openRouter:
            guard credentials.apiKey?.isEmpty == false else {
                throw CodexConfigurationSyncError.missingAPIKey
            }
            object = ["OPENAI_API_KEY": request.network.openRouterGatewayAPIKey]
        }

        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    private func renderConfigTOML(
        request: CodexConfigurationSyncRequest,
        existingText: String
    ) -> String {
        var text = existingText
        text = self.upsertSetting(text, key: "model_provider", value: "\"openai\"")
        text = self.removeSetting(text, key: "oss_provider")
        text = self.removeSetting(text, key: "openai_base_url")
        text = self.removeSetting(text, key: "preferred_auth_method")
        text = self.removeBlock(text, key: "OpenAI")
        text = self.removeBlock(text, key: "openai")

        if request.provider.kind == .openAIOAuth,
           request.accountUsageMode == .aggregateGateway {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(request.network.openAIAccountGatewayBaseURL)
            )
        } else if request.provider.kind == .openRouter {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(request.network.openRouterGatewayBaseURL)
            )
        } else if request.provider.kind == .openAICompatible,
                  request.provider.wireAPI == .chat {
            text = self.upsertSetting(
                text,
                key: "openai_base_url",
                value: self.quote(request.network.chatCompletionsGatewayBaseURL)
            )
        } else if request.provider.kind == .openAICompatible,
                  let baseURL = request.provider.baseURL {
            text = self.upsertSetting(text, key: "openai_base_url", value: self.quote(baseURL))
        }

        return text.hasSuffix("\n") ? text : text + "\n"
    }

    private func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func upsertSetting(_ text: String, key: String, value: String) -> String {
        let line = "\(key) = \(value)"
        let pattern = #"(?m)^#(key)\s*=.*$"#
            .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        if regex.firstMatch(in: text, range: range) != nil {
            return regex.stringByReplacingMatches(in: text, range: range, withTemplate: line)
        }
        return line + "\n" + text
    }

    private func removeSetting(_ text: String, key: String) -> String {
        let pattern = #"(?m)^#(key)\s*=.*$\n?"#
            .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func removeBlock(_ text: String, key: String) -> String {
        let pattern = #"(?ms)^\[model_providers\.#(key)\]\n.*?(?=^\[|\Z)"#
            .replacingOccurrences(of: "#(key)", with: NSRegularExpression.escapedPattern(for: key))
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }
}
