import AppKit
import Foundation
import SwiftUI

@MainActor
protocol OpenAILoginOAuthManaging: AnyObject {
    var pendingAuthURL: String? { get }
    func startOAuth(
        openBrowser: Bool,
        activate: Bool,
        completion: @escaping (Result<CompletedOpenAIOAuthFlow, Error>) -> Void
    )
    func completeOAuth(from input: String)
    func cancel()
}

protocol LocalhostOAuthCallbackServing: AnyObject {
    func start() throws
    func stop()
}

extension OAuthManager: OpenAILoginOAuthManaging {}
extension LocalhostOAuthCallbackServer: LocalhostOAuthCallbackServing {}

extension Notification.Name {
    static let openAILoginDidSucceed = Notification.Name("com.codexpanel.openai-login.did-succeed")
    static let openAILoginDidFail = Notification.Name("com.codexpanel.openai-login.did-fail")
}

private struct OpenAILoginWindowView: View {
    @ObservedObject private var oauth = OAuthManager.shared
    private let callbackBaseURL: String

    init(callbackBaseURL: String = CodexPanelRuntimeProfile.current.network.oauthRedirectURI) {
        self.callbackBaseURL = callbackBaseURL
    }

    var body: some View {
        OpenAIManualOAuthSheet(
            authURL: oauth.pendingAuthURL ?? "",
            callbackBaseURL: self.callbackBaseURL,
            isAuthenticating: oauth.isAuthenticating,
            errorMessage: oauth.errorMessage,
            callbackInput: Binding(
                get: { oauth.callbackInput },
                set: { oauth.callbackInput = $0 }
            )
        ) { input in
            oauth.completeOAuth(from: input)
        } onOpenBrowser: {
            guard let authURL = oauth.pendingAuthURL, let url = URL(string: authURL) else { return }
            NSWorkspace.shared.open(url)
        } onCopyLink: {
            guard let authURL = oauth.pendingAuthURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(authURL, forType: .string)
        } onCancel: {
            OpenAILoginCoordinator.shared.cancel()
        }
    }
}

@MainActor
final class OpenAILoginCoordinator {
    static let shared = OpenAILoginCoordinator()

    static let windowID = "oauth-login"
    static var loginURLScheme: String {
        CodexPanelRuntimeProfile.current.oauthURLScheme
    }
    static let loginHost = "login"

    private let oauth: any OpenAILoginOAuthManaging
    private let callbackServerFactory: (@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing
    private let openWindowAction: () -> Void
    private let closeWindowAction: () -> Void

    private var callbackServer: (any LocalhostOAuthCallbackServing)?

    init(
        oauth: (any OpenAILoginOAuthManaging)? = nil,
        callbackServerFactory: ((@escaping @MainActor (String) -> Void) -> any LocalhostOAuthCallbackServing)? = nil,
        openWindowAction: (() -> Void)? = nil,
        closeWindowAction: (() -> Void)? = nil
    ) {
        self.oauth = oauth ?? OAuthManager.shared
        self.callbackServerFactory = callbackServerFactory ?? {
            LocalhostOAuthCallbackServer(onCallback: $0)
        }
        self.openWindowAction = openWindowAction ?? Self.defaultOpenWindow
        self.closeWindowAction = closeWindowAction ?? Self.defaultCloseWindow
    }

    func start() {
        oauth.startOAuth(openBrowser: false, activate: false) { result in
            self.stopCallbackServer()
            switch result {
            case .success(let completion):
                let store = TokenStore.shared
                store.load()
                Task {
                    await WhamService.shared.refreshOne(account: completion.account, store: store)
                }
                self.closeWindowAction()
                NotificationCenter.default.post(
                    name: .openAILoginDidSucceed,
                    object: nil,
                    userInfo: [
                        "active": completion.active,
                        "message": completion.active
                            ? "Updated Codex configuration. Changes apply to new sessions."
                            : "Saved OpenAI account.",
                    ]
                )
            case .failure(let error):
                NotificationCenter.default.post(
                    name: .openAILoginDidFail,
                    object: nil,
                    userInfo: ["message": error.localizedDescription]
                )
            }
        }

        self.startCallbackServer()
        self.openWindowAction()
    }

    func cancel() {
        self.stopCallbackServer()
        self.oauth.cancel()
        self.closeWindowAction()
    }

    func closeWindow() {
        self.stopCallbackServer()
        self.closeWindowAction()
    }

    private static func defaultOpenWindow() {
        DetachedWindowPresenter.shared.show(
            id: Self.windowID,
            title: "OpenAI OAuth",
            size: CGSize(width: 560, height: 420)
        ) {
            OpenAILoginWindowView()
        }
    }

    private static func defaultCloseWindow() {
        DetachedWindowPresenter.shared.close(id: Self.windowID)
    }

    private func startCallbackServer() {
        self.stopCallbackServer()

        let server = self.callbackServerFactory { callbackURL in
            self.oauth.completeOAuth(from: callbackURL)
        }
        do {
            try server.start()
            self.callbackServer = server
        } catch {
            NSLog("codexpanel localhost OAuth callback listener unavailable: %@", error.localizedDescription)
            self.callbackServer = nil
        }
    }

    private func stopCallbackServer() {
        self.callbackServer?.stop()
        self.callbackServer = nil
    }
}

enum CodexPanelURLRouter {
    @MainActor
    static func handle(_ url: URL) {
        guard let command = CodexPanelURLCommandParser.parse(url) else { return }
        do {
            try CodexPanelUICommandRouter.shared.handle(command)
        } catch {
            NSLog("codexpanel URL command failed: %@", error.localizedDescription)
        }
    }
}
