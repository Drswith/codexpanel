import SwiftUI

@main
struct codexPanelApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver
    @StateObject private var menuController = MenuBarStatusItemController.shared

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L.settings) {
                    CodexPanelUICommandRouter.shared.openSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(
            menuController.presentation.title,
            systemImage: menuController.presentation.iconName,
            isInserted: Binding(
                get: { menuController.isInserted },
                set: { if menuController.isInserted != $0 { menuController.isInserted = $0 } }
            )
        ) {
            NativeMenuBarContent()
        }
        .menuBarExtraStyle(.window)
    }
}
