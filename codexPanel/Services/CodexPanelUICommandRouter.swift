import AppKit
import Foundation
import SwiftUI

@MainActor
final class CodexPanelUICommandRouter {
    static let shared = CodexPanelUICommandRouter()

    static let settingsWindowID = "openai-settings"
    static let settingsWindowSize = CGSize(width: 740, height: 520)

    private let store: TokenStore
    private let updateCoordinator: UpdateCoordinator
    private let codexAppPathPanelService: CodexAppPathPanelService

    init(
        store: TokenStore? = nil,
        updateCoordinator: UpdateCoordinator? = nil,
        codexAppPathPanelService: CodexAppPathPanelService? = nil
    ) {
        self.store = store ?? .shared
        self.updateCoordinator = updateCoordinator ?? .shared
        self.codexAppPathPanelService = codexAppPathPanelService ?? .shared
    }

    func openSettings() {
        self.requestCloseMenu()
        DetachedWindowPresenter.shared.show(
            id: Self.settingsWindowID,
            title: L.settingsWindowTitle,
            size: Self.settingsWindowSize,
            configuration: .openAISettings
        ) {
            SettingsWindowView(
                store: self.store,
                updateCoordinator: self.updateCoordinator,
                codexAppPathPanelService: self.codexAppPathPanelService
            )
        }
    }

    func openLogin() {
        self.requestCloseMenu()
        OpenAILoginCoordinator.shared.start()
    }

    private func requestCloseMenu() {
        NotificationCenter.default.post(name: .codexpanelRequestCloseStatusItemMenu, object: nil)
    }
}
