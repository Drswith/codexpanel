import AppKit
import Foundation
import SwiftUI

enum CodexPanelUIRouteError: LocalizedError, Equatable {
    case unsupportedCommand

    var errorDescription: String? {
        switch self {
        case .unsupportedCommand:
            return "Unsupported codexpanel URL command."
        }
    }
}

enum CodexPanelViewAction: String {
    case open
    case close
}

enum CodexPanelViewTarget: String {
    case settings
    case menu
    case login
    case all
}

struct CodexPanelViewCommand {
    var action: CodexPanelViewAction
    var target: CodexPanelViewTarget
    var settingsPage: SettingsPage?
}

enum CodexPanelURLCommand {
    case oauthLogin
    case view(CodexPanelViewCommand)
}

@MainActor
struct CodexPanelUICommandRouterHandlers {
    var openSettings: (SettingsPage) -> Void
    var closeSettings: () -> Void
    var openMenu: () -> Void
    var closeMenu: () -> Void
    var openLogin: () -> Void
    var closeLogin: () -> Void
    var requestCloseMenu: () -> Void

    static func live(
        store: TokenStore,
        updateCoordinator: UpdateCoordinator,
        codexAppPathPanelService: CodexAppPathPanelService
    ) -> CodexPanelUICommandRouterHandlers {
        CodexPanelUICommandRouterHandlers(
            openSettings: { page in
                DetachedWindowPresenter.shared.show(
                    id: CodexPanelUICommandRouter.settingsWindowID,
                    title: L.settingsWindowTitle,
                    size: CodexPanelUICommandRouter.settingsWindowSize,
                    configuration: .openAISettings
                ) {
                    SettingsWindowView(
                        store: store,
                        updateCoordinator: updateCoordinator,
                        codexAppPathPanelService: codexAppPathPanelService,
                        initialPage: page
                    ) {
                        DetachedWindowPresenter.shared.close(id: CodexPanelUICommandRouter.settingsWindowID)
                    }
                }
            },
            closeSettings: {
                DetachedWindowPresenter.shared.close(id: CodexPanelUICommandRouter.settingsWindowID)
            },
            openMenu: {
                MenuBarStatusItemController.shared.openMenuFromExternalCommand()
            },
            closeMenu: {
                MenuBarStatusItemController.shared.closeMenuFromExternalCommand()
            },
            openLogin: {
                OpenAILoginCoordinator.shared.start()
            },
            closeLogin: {
                OpenAILoginCoordinator.shared.closeWindow()
            },
            requestCloseMenu: {
                NotificationCenter.default.post(name: .codexpanelRequestCloseStatusItemMenu, object: nil)
            }
        )
    }
}

@MainActor
enum CodexPanelURLCommandParser {
    static let oauthScheme = OpenAILoginCoordinator.loginURLScheme
    static let automationScheme = "codexpanel"
    static let viewHost = "view"

    static func parse(_ url: URL) -> CodexPanelURLCommand? {
        guard let scheme = url.scheme?.lowercased() else { return nil }

        if scheme == self.oauthScheme.lowercased() {
            let host = url.host?.lowercased()
            let path = url.path.lowercased()
            if host == OpenAILoginCoordinator.loginHost || path == "/\(OpenAILoginCoordinator.loginHost)" {
                return .oauthLogin
            }
            return nil
        }

        guard scheme == self.automationScheme else { return nil }
        guard url.host?.lowercased() == self.viewHost else { return nil }

        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2,
              let action = CodexPanelViewAction(rawValue: components[0].lowercased()),
              let target = CodexPanelViewTarget(rawValue: components[1].lowercased()) else {
            return nil
        }

        var settingsPage: SettingsPage?
        if target == .settings {
            settingsPage = self.settingsPage(from: url)
        }
        return .view(CodexPanelViewCommand(action: action, target: target, settingsPage: settingsPage))
    }

    private static func settingsPage(from url: URL) -> SettingsPage {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name.lowercased() == "page" })?.value?.lowercased() else {
            return .accounts
        }
        if value == "updates" {
            return .about
        }
        return SettingsPage(rawValue: value) ?? .accounts
    }
}

@MainActor
final class CodexPanelUICommandRouter {
    static let shared = CodexPanelUICommandRouter()

    static let settingsWindowID = "openai-settings"
    static let settingsWindowSize = CGSize(width: 760, height: 560)

    private let handlers: CodexPanelUICommandRouterHandlers

    init(
        store: TokenStore? = nil,
        updateCoordinator: UpdateCoordinator? = nil,
        codexAppPathPanelService: CodexAppPathPanelService? = nil
    ) {
        let resolvedStore = store ?? .shared
        let resolvedUpdateCoordinator = updateCoordinator ?? .shared
        let resolvedPathPanelService = codexAppPathPanelService ?? .shared
        self.handlers = .live(
            store: resolvedStore,
            updateCoordinator: resolvedUpdateCoordinator,
            codexAppPathPanelService: resolvedPathPanelService
        )
    }

    init(handlers: CodexPanelUICommandRouterHandlers) {
        self.handlers = handlers
    }

    func handle(_ command: CodexPanelURLCommand) throws {
        switch command {
        case .oauthLogin:
            self.openLogin()
        case .view(let command):
            try self.handleViewCommand(command)
        }
    }

    func openSettings(page: SettingsPage = .accounts) {
        self.handlers.requestCloseMenu()
        self.handlers.openSettings(page)
    }

    func closeSettings() {
        self.handlers.closeSettings()
    }

    func openMenu() {
        self.handlers.openMenu()
    }

    func closeMenu() {
        self.handlers.closeMenu()
    }

    func openLogin() {
        self.handlers.requestCloseMenu()
        self.handlers.openLogin()
    }

    func closeLogin() {
        self.handlers.closeLogin()
    }

    func closeAll() {
        self.closeSettings()
        self.closeMenu()
        self.closeLogin()
    }

    private func handleViewCommand(_ command: CodexPanelViewCommand) throws {
        switch (command.action, command.target) {
        case (.open, .settings):
            self.openSettings(page: command.settingsPage ?? .accounts)
        case (.close, .settings):
            self.closeSettings()
        case (.open, .menu):
            self.openMenu()
        case (.close, .menu):
            self.closeMenu()
        case (.open, .login):
            self.openLogin()
        case (.close, .login):
            self.closeLogin()
        case (.close, .all):
            self.closeAll()
        case (.open, .all):
            throw CodexPanelUIRouteError.unsupportedCommand
        }
    }
}
