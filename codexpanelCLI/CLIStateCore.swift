import Foundation

struct CLIStateComputationInput {
    var bundleIdentifier: String = codexPanelBundleIdentifier
    var appRunning: Bool
    var pid: Int32?
    var accessibilityTrusted: Bool
    var menuVisible: Bool
    var visibleWindows: [String]
}

enum CLIStateResultBuilder {
    static func build(from input: CLIStateComputationInput) -> StateResult {
        if input.appRunning == false {
            return StateResult(
                bundleIdentifier: input.bundleIdentifier,
                appRunning: false,
                appVersion: nil,
                pid: nil,
                menuVisible: false,
                visibleWindows: [],
                accessibilityTrusted: input.accessibilityTrusted
            )
        }

        if input.accessibilityTrusted == false {
            return StateResult(
                bundleIdentifier: input.bundleIdentifier,
                appRunning: true,
                appVersion: nil,
                pid: input.pid,
                menuVisible: false,
                visibleWindows: [],
                accessibilityTrusted: false
            )
        }

        return StateResult(
            bundleIdentifier: input.bundleIdentifier,
            appRunning: true,
            appVersion: nil,
            pid: input.pid,
            menuVisible: input.menuVisible,
            visibleWindows: input.visibleWindows,
            accessibilityTrusted: true
        )
    }
}
