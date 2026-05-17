import Foundation

struct CLIRuntimeIdentity: Equatable {
    var commandName: String
    var bundleIdentifier: String
    var urlScheme: String

    static let debug = CLIRuntimeIdentity(
        commandName: "codexpanel-dev",
        bundleIdentifier: "com.codexpanel.dev",
        urlScheme: "codexpanel-dev"
    )

    static let release = CLIRuntimeIdentity(
        commandName: "codexpanel",
        bundleIdentifier: "com.codexpanel",
        urlScheme: "codexpanel"
    )

    static var current: CLIRuntimeIdentity {
        #if DEBUG
        return .debug
        #else
        return .release
        #endif
    }
}
