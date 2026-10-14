import AppKit
import SwiftUI

@main
private enum CodexPanelEntryPoint {
    @MainActor
    static func main() {
        if #available(macOS 15, *) {
            codexPanelApp<OnDemandSettingsWindowScene>.main()
        } else {
            codexPanelApp<NativeSettingsWindowScene>.main()
        }
    }
}

private protocol SettingsWindowSceneProviding: Scene {
    init()
}

private struct codexPanelApp<SettingsScene: SettingsWindowSceneProviding>: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver
    @StateObject private var menuController = MenuBarStatusItemController.shared

    var body: some Scene {
        SettingsScene()
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button(L.settings) { CodexPanelUICommandRouter.shared.openSettings() }
                        .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(replacing: .newItem) { }
            }

        MenuBarExtra(isInserted: Binding(
            get: { menuController.isInserted },
            set: { if menuController.isInserted != $0 { menuController.isInserted = $0 } }
        )) {
            NativeMenuBarContent()
        } label: {
            NativeMenuBarSceneLabel(controller: menuController)
        }
        .menuBarExtraStyle(.window)
        .commandsRemoved()
    }

}

private struct NativeSettingsWindowScene: SettingsWindowSceneProviding {
    var body: some Scene {
        Window(L.settingsWindowTitle, id: CodexPanelUICommandRouter.settingsWindowID) {
            NativeSettingsSceneContent()
        }
        .defaultSize(width: 740, height: 520)
        .windowResizability(.contentMinSize)
    }
}

@available(macOS 15, *)
private struct OnDemandSettingsWindowScene: SettingsWindowSceneProviding {
    var body: some Scene {
        NativeSettingsWindowScene()
            .defaultLaunchBehavior(.suppressed)
            .restorationBehavior(.disabled)
    }
}

private struct NativeMenuBarSceneLabel: View {
    @ObservedObject var controller: MenuBarStatusItemController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Image(systemName: self.controller.presentation.iconName)
            if !self.controller.presentation.title.isEmpty { Text(self.controller.presentation.title) }
        }
        .onAppear {
            CodexPanelUICommandRouter.shared.registerSettingsSceneAction {
                NSApp.activate(ignoringOtherApps: true)
                self.openWindow(id: CodexPanelUICommandRouter.settingsWindowID)
            }
        }
    }
}

private struct NativeSettingsSceneContent: View {
    @ObservedObject private var controller = MenuBarStatusItemController.shared

    var body: some View {
        Group {
            if self.controller.isRuntimeReady {
                SettingsWindowView(store: .shared, codexAppPathPanelService: .shared)
            } else {
                ProgressView().onAppear { self.controller.prepareMenuContent() }
            }
        }
    }
}
