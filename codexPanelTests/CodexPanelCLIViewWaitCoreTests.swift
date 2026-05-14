import Foundation
import XCTest

final class CodexPanelCLIViewWaitCoreTests: XCTestCase {
    func testEvaluatorOpenSettingsSatisfiedWhenSettingsWindowVisible() {
        let command = CLIViewWaitCommand(action: .open, target: .settings)
        let state = self.makeState(
            visibleWindows: ["@\(settingsWindowIdentifier)"],
            menuVisible: false
        )

        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: state))
    }

    func testEvaluatorCloseAllRequiresAllTargetsHiddenAndMenuInvisible() {
        let command = CLIViewWaitCommand(action: .close, target: .all)
        let notSatisfied = self.makeState(
            visibleWindows: ["@\(settingsWindowIdentifier)"],
            menuVisible: false
        )
        let satisfied = self.makeState(
            visibleWindows: [],
            menuVisible: false
        )

        XCTAssertFalse(CLIViewWaitEvaluator.isSatisfied(command: command, state: notSatisfied))
        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: satisfied))
    }

    func testEvaluatorOpenMenuSatisfiedByMenuVisibleFlag() {
        let command = CLIViewWaitCommand(action: .open, target: .menu)
        let state = self.makeState(
            visibleWindows: [],
            menuVisible: true
        )

        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: state))
    }

    func testEvaluatorCloseSettingsSatisfiedWhenSettingsWindowHidden() {
        let command = CLIViewWaitCommand(action: .close, target: .settings)
        let state = self.makeState(visibleWindows: [], menuVisible: false)

        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: state))
    }

    func testEvaluatorCloseMenuRequiresWindowAndMenuFlagHidden() {
        let command = CLIViewWaitCommand(action: .close, target: .menu)
        let menuWindowVisible = self.makeState(
            visibleWindows: ["@\(menuWindowIdentifier)"],
            menuVisible: false
        )
        let menuFlagVisible = self.makeState(
            visibleWindows: [],
            menuVisible: true
        )
        let hidden = self.makeState(
            visibleWindows: [],
            menuVisible: false
        )

        XCTAssertFalse(CLIViewWaitEvaluator.isSatisfied(command: command, state: menuWindowVisible))
        XCTAssertFalse(CLIViewWaitEvaluator.isSatisfied(command: command, state: menuFlagVisible))
        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: hidden))
    }

    func testEvaluatorCloseLoginSatisfiedWhenLoginWindowHidden() {
        let command = CLIViewWaitCommand(action: .close, target: .login)
        let state = self.makeState(visibleWindows: [], menuVisible: false)

        XCTAssertTrue(CLIViewWaitEvaluator.isSatisfied(command: command, state: state))
    }

    func testPollerReturnsTrueWhenStateTransitionsBeforeTimeout() {
        let initial = self.makeState(visibleWindows: [], menuVisible: false)
        let final = self.makeState(visibleWindows: ["@\(loginWindowIdentifier)"], menuVisible: false)
        let provider = SequenceStateProvider(states: [initial, final])
        let command = CLIViewWaitCommand(action: .open, target: .login)

        var now = Date(timeIntervalSince1970: 0)
        let poller = CLIViewWaitPoller(
            now: { now },
            runLoopStep: { step in
                now = now.addingTimeInterval(step)
            }
        )

        let result = poller.waitUntilSatisfied(command: command, timeout: 1.0, provider: provider)
        XCTAssertTrue(result)
    }

    func testPollerReturnsFalseWhenTimedOut() {
        let provider = SequenceStateProvider(
            states: [self.makeState(visibleWindows: [], menuVisible: false)]
        )
        let command = CLIViewWaitCommand(action: .open, target: .settings)

        var now = Date(timeIntervalSince1970: 0)
        let poller = CLIViewWaitPoller(
            now: { now },
            runLoopStep: { step in
                now = now.addingTimeInterval(step)
            }
        )

        let result = poller.waitUntilSatisfied(command: command, timeout: 0.5, provider: provider)
        XCTAssertFalse(result)
    }

    func testPollerReturnsTrueWhenCloseSettingsStateTransitionsToHidden() {
        let initial = self.makeState(
            visibleWindows: ["@\(settingsWindowIdentifier)"],
            menuVisible: false
        )
        let final = self.makeState(visibleWindows: [], menuVisible: false)
        let provider = SequenceStateProvider(states: [initial, final])
        let command = CLIViewWaitCommand(action: .close, target: .settings)

        var now = Date(timeIntervalSince1970: 0)
        let poller = CLIViewWaitPoller(
            now: { now },
            runLoopStep: { step in
                now = now.addingTimeInterval(step)
            }
        )

        let result = poller.waitUntilSatisfied(command: command, timeout: 1.0, provider: provider)
        XCTAssertTrue(result)
    }

    private func makeState(
        visibleWindows: [String],
        menuVisible: Bool
    ) -> StateResult {
        StateResult(
            appRunning: true,
            appVersion: "1.0.0",
            pid: 123,
            menuVisible: menuVisible,
            visibleWindows: visibleWindows,
            accessibilityTrusted: true
        )
    }
}

private final class SequenceStateProvider: CLIViewStateProviding {
    private let states: [StateResult]
    private var index: Int = 0

    init(states: [StateResult]) {
        self.states = states
    }

    func currentState() -> StateResult {
        guard self.states.isEmpty == false else {
            return StateResult(
                appRunning: false,
                appVersion: nil,
                pid: nil,
                menuVisible: false,
                visibleWindows: [],
                accessibilityTrusted: true
            )
        }
        let snapshotIndex = min(self.index, self.states.count - 1)
        let state = self.states[snapshotIndex]
        if self.index < self.states.count - 1 {
            self.index += 1
        }
        return state
    }
}
