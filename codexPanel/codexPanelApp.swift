import SwiftUI

@main
struct codexPanelApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycleObserver.self) private var lifecycleObserver

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
