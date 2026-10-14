import AppKit
import Foundation
import SwiftUI

@MainActor
final class CodexPanelUICommandRouter {
    static let shared = CodexPanelUICommandRouter()

    static let settingsWindowID = "openai-settings"
    static let settingsWindowSize = CGSize(width: 740, height: 520)

    private var settingsSceneAction: (@MainActor () -> Void)?
    private var hasPendingSettingsRequest = false
    private let prepareRuntime: @MainActor () -> Void

    init(prepareRuntime: @escaping @MainActor () -> Void = { MenuBarStatusItemController.shared.prepareMenuContent() }) {
        self.prepareRuntime = prepareRuntime
    }

    func registerSettingsSceneAction(_ action: @escaping @MainActor () -> Void) {
        self.settingsSceneAction = action
        if self.hasPendingSettingsRequest {
            self.hasPendingSettingsRequest = false
            DispatchQueue.main.async { action() }
        }
    }

    func openSettings() {
        self.requestCloseMenu()
        self.prepareRuntime()
        guard let action = self.settingsSceneAction else {
            self.hasPendingSettingsRequest = true
            return
        }
        // 等菜单退出本轮显示事务后再打开原生窗口场景。
        DispatchQueue.main.async { action() }
    }

    func openLogin() {
        self.requestCloseMenu()
        OpenAILoginCoordinator.shared.start()
    }

    private func requestCloseMenu() {
        NotificationCenter.default.post(name: .codexpanelRequestCloseStatusItemMenu, object: nil)
    }
}
