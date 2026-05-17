import Foundation

enum CLIViewURLBuilder {
    static func makeViewURL(
        command: ViewCommand,
        identity: CLIRuntimeIdentity = .current
    ) -> URL? {
        var components = URLComponents()
        components.scheme = identity.urlScheme
        components.host = "view"
        components.path = "/\(command.action.rawValue)/\(command.target.rawValue)"
        if command.action == .open, command.target == .settings, let page = command.page {
            components.queryItems = [URLQueryItem(name: "page", value: page.rawValue)]
        }
        return components.url
    }
}
