import Foundation

protocol CLIViewStateProviding {
    func currentState() -> StateResult
}

struct CLIViewWaitCommand {
    var action: ViewAction
    var target: ViewTarget
}

struct CLIViewWaitPoller {
    var now: () -> Date = Date.init
    var runLoopStep: (TimeInterval) -> Void = { interval in
        RunLoop.current.run(until: Date(timeIntervalSinceNow: interval))
    }

    func waitUntilSatisfied(
        command: CLIViewWaitCommand,
        timeout: TimeInterval,
        provider: CLIViewStateProviding
    ) -> Bool {
        let deadline = self.now().addingTimeInterval(timeout)
        while self.now() <= deadline {
            if CLIViewWaitEvaluator.isSatisfied(command: command, state: provider.currentState()) {
                return true
            }
            self.runLoopStep(0.2)
        }
        return false
    }
}

enum CLIViewWaitEvaluator {
    static func isSatisfied(command: CLIViewWaitCommand, state: StateResult) -> Bool {
        let visible = Set(state.visibleWindows)
        switch (command.action, command.target) {
        case (.open, .settings):
            return visible.contains("@\(settingsWindowIdentifier)")
        case (.close, .settings):
            return visible.contains("@\(settingsWindowIdentifier)") == false
        case (.open, .login):
            return visible.contains("@\(loginWindowIdentifier)")
        case (.close, .login):
            return visible.contains("@\(loginWindowIdentifier)") == false
        case (.open, .menu):
            return state.menuVisible || visible.contains("@\(menuWindowIdentifier)")
        case (.close, .menu):
            return state.menuVisible == false && visible.contains("@\(menuWindowIdentifier)") == false
        case (.close, .all):
            return visible.contains("@\(settingsWindowIdentifier)") == false &&
                visible.contains("@\(loginWindowIdentifier)") == false &&
                visible.contains("@\(menuWindowIdentifier)") == false &&
                state.menuVisible == false
        case (.open, .all):
            return false
        }
    }
}

