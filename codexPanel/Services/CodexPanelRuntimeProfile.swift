import Foundation

enum CodexPanelRuntimeChannel: String, Equatable {
    case debug
    case release
}

enum CodexPanelHomeSource: String, Equatable {
    case environmentOverride
    case debugDefault
    case realHome
}

struct CodexPanelRuntimeNetworkConfiguration: Equatable {
    var host: String
    var oauthCallbackPort: UInt16
    var openAIAccountGatewayPort: UInt16
    var openRouterGatewayPort: UInt16
    var chatCompletionsGatewayPort: UInt16
    var oauthCallbackPath: String

    var oauthRedirectURI: String {
        "http://\(self.host):\(self.oauthCallbackPort)\(self.oauthCallbackPath)"
    }

    var openAIAccountGatewayBaseURLString: String {
        "http://\(self.host):\(self.openAIAccountGatewayPort)/v1"
    }

    var openRouterGatewayBaseURLString: String {
        "http://\(self.host):\(self.openRouterGatewayPort)/v1"
    }

    var chatCompletionsGatewayBaseURLString: String {
        "http://\(self.host):\(self.chatCompletionsGatewayPort)/v1"
    }
}

struct CodexPanelRuntimeProfile: Equatable {
    static let homeOverrideEnvironmentKey = "CODEXPANEL_HOME"
    static let allowRealHomeEnvironmentKey = "CODEXPANEL_ALLOW_REAL_HOME"

    let channel: CodexPanelRuntimeChannel
    let homeRoot: URL
    let homeSource: CodexPanelHomeSource

    var bundleIdentifier: String {
        switch self.channel {
        case .debug:
            return "com.codexpanel.dev"
        case .release:
            return "com.codexpanel"
        }
    }

    var automationURLScheme: String {
        switch self.channel {
        case .debug:
            return "codexpanel-dev"
        case .release:
            return "codexpanel"
        }
    }

    var cliCommandName: String {
        switch self.channel {
        case .debug:
            return "codexpanel-dev"
        case .release:
            return "codexpanel"
        }
    }

    var oauthURLScheme: String {
        switch self.channel {
        case .debug:
            return "com.codexpanel.dev.oauth"
        case .release:
            return "com.codexpanel.oauth"
        }
    }

    var network: CodexPanelRuntimeNetworkConfiguration {
        switch self.channel {
        case .debug:
            return CodexPanelRuntimeNetworkConfiguration(
                host: "localhost",
                oauthCallbackPort: 1555,
                openAIAccountGatewayPort: 1556,
                openRouterGatewayPort: 1557,
                chatCompletionsGatewayPort: 1558,
                oauthCallbackPath: "/auth/callback"
            )
        case .release:
            return CodexPanelRuntimeNetworkConfiguration(
                host: "localhost",
                oauthCallbackPort: 1455,
                openAIAccountGatewayPort: 1456,
                openRouterGatewayPort: 1457,
                chatCompletionsGatewayPort: 1458,
                oauthCallbackPath: "/auth/callback"
            )
        }
    }

    var usesRealHome: Bool {
        self.homeSource == .realHome
    }

    static var current: CodexPanelRuntimeProfile {
        self.resolve(
            channel: self.currentBuildChannel,
            environment: ProcessInfo.processInfo.environment,
            defaultHome: self.defaultSystemHome()
        )
    }

    static func resolve(
        channel: CodexPanelRuntimeChannel,
        environment: [String: String],
        defaultHome: URL
    ) -> CodexPanelRuntimeProfile {
        if let override = environment[self.homeOverrideEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           override.isEmpty == false {
            return CodexPanelRuntimeProfile(
                channel: channel,
                homeRoot: URL(fileURLWithPath: override, isDirectory: true),
                homeSource: .environmentOverride
            )
        }

        switch channel {
        case .debug:
            if self.environmentFlagIsEnabled(environment[self.allowRealHomeEnvironmentKey]) {
                return CodexPanelRuntimeProfile(
                    channel: channel,
                    homeRoot: defaultHome,
                    homeSource: .realHome
                )
            }

            return CodexPanelRuntimeProfile(
                channel: channel,
                homeRoot: self.defaultDebugHome(defaultHome: defaultHome),
                homeSource: .debugDefault
            )
        case .release:
            return CodexPanelRuntimeProfile(
                channel: channel,
                homeRoot: defaultHome,
                homeSource: .realHome
            )
        }
    }

    private static var currentBuildChannel: CodexPanelRuntimeChannel {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }

    private static func environmentFlagIsEnabled(_ rawValue: String?) -> Bool {
        guard let value = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              value.isEmpty == false else {
            return false
        }
        return ["1", "true", "yes", "y", "on"].contains(value)
    }

    private static func defaultDebugHome(defaultHome: URL) -> URL {
        defaultHome
            .appendingPathComponent(".codexpanel-dev", isDirectory: true)
            .appendingPathComponent("home", isDirectory: true)
    }

    private static func defaultSystemHome() -> URL {
        if let pw = getpwuid(getuid()), let pwDir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: pwDir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
