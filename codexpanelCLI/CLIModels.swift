import Foundation

let codexPanelBundleIdentifier = "com.codexpanel"
let codexPanelURLScheme = "codexpanel"
let codexPanelWindowIdentifierPrefix = "codexpanel.window."
let settingsWindowIdentifier = "\(codexPanelWindowIdentifierPrefix)openai-settings"
let loginWindowIdentifier = "\(codexPanelWindowIdentifierPrefix)oauth-login"
let menuWindowIdentifier = "\(codexPanelWindowIdentifierPrefix)menu"

enum ViewAction: String {
    case open
    case close
}

enum ViewTarget: String {
    case settings
    case menu
    case login
    case all
}

enum CLISettingsPage: String {
    case accounts
    case records
    case usage
    case updates
}

enum SnapshotFormat: String {
    case tree
    case json
}

enum SnapshotTarget: String, Codable {
    case auto
    case settings
    case menu
    case login
    case all
}

struct ViewCommand {
    var action: ViewAction
    var target: ViewTarget
    var page: CLISettingsPage?
    var waitSeconds: TimeInterval?
    var jsonOutput: Bool
}

struct StateCommand {
    var jsonOutput: Bool
}

struct SnapshotCommand {
    var format: SnapshotFormat
    var target: SnapshotTarget
}

struct DoctorCommand {
    var jsonOutput: Bool
}

enum CLICommand {
    case view(ViewCommand)
    case state(StateCommand)
    case snapshot(SnapshotCommand)
    case doctor(DoctorCommand)
}

struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct SnapshotNode: Codable, Equatable {
    var ref: String
    var role: String
    var title: String?
    var label: String?
    var valueSummary: String?
    var enabled: Bool?
    var focused: Bool?
    var frame: WindowFrame?
    var children: [SnapshotNode]
}

struct SnapshotWindow: Codable, Equatable {
    var kind: SnapshotTarget
    var windowRef: String
    var title: String?
    var nodes: [SnapshotNode]
}

struct SnapshotResult: Codable, Equatable {
    var bundleIdentifier: String
    var pid: Int32
    var target: SnapshotTarget
    var windows: [SnapshotWindow]
}

struct StateResult: Codable, Equatable {
    var appRunning: Bool
    var appVersion: String?
    var pid: Int32?
    var menuVisible: Bool
    var visibleWindows: [String]
    var accessibilityTrusted: Bool
}

struct DoctorResult: Codable, Equatable {
    var appInstalled: Bool
    var appBundlePath: String?
    var appRunning: Bool
    var pid: Int32?
    var appVersion: String?
    var helperBundled: Bool
    var helperPath: String?
    var cliSymlinkPath: String
    var cliSymlinkExists: Bool
    var cliSymlinkTarget: String?
    var accessibilityTrusted: Bool
}

struct ViewResult: Encodable, Equatable {
    var ok: Bool
    var action: String
    var target: String
    var page: String?
    var waitSeconds: Double?
}
