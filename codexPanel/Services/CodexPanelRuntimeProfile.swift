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

struct CodexPanelRuntimeProfile: Equatable {
    static let homeOverrideEnvironmentKey = "CODEXPANEL_HOME"
    static let allowRealHomeEnvironmentKey = "CODEXPANEL_ALLOW_REAL_HOME"

    let channel: CodexPanelRuntimeChannel
    let homeRoot: URL
    let homeSource: CodexPanelHomeSource

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
