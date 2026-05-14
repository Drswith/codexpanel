import XCTest

final class CodexPanelCLIStateCoreTests: XCTestCase {
    func testStateBuilderWhenAppNotRunning() {
        let state = CLIStateResultBuilder.build(
            from: CLIStateComputationInput(
                appRunning: false,
                pid: nil,
                accessibilityTrusted: true,
                menuVisible: true,
                visibleWindows: ["@unexpected"]
            )
        )

        XCTAssertEqual(state.appRunning, false)
        XCTAssertNil(state.pid)
        XCTAssertEqual(state.menuVisible, false)
        XCTAssertEqual(state.visibleWindows, [])
        XCTAssertEqual(state.accessibilityTrusted, true)
    }

    func testStateBuilderWhenAccessibilityNotTrusted() {
        let state = CLIStateResultBuilder.build(
            from: CLIStateComputationInput(
                appRunning: true,
                pid: 123,
                accessibilityTrusted: false,
                menuVisible: true,
                visibleWindows: ["@\(settingsWindowIdentifier)"]
            )
        )

        XCTAssertEqual(state.appRunning, true)
        XCTAssertEqual(state.pid, 123)
        XCTAssertEqual(state.menuVisible, false)
        XCTAssertEqual(state.visibleWindows, [])
        XCTAssertEqual(state.accessibilityTrusted, false)
    }

    func testStateBuilderWhenAppRunningAndTrusted() {
        let state = CLIStateResultBuilder.build(
            from: CLIStateComputationInput(
                appRunning: true,
                pid: 321,
                accessibilityTrusted: true,
                menuVisible: true,
                visibleWindows: ["@\(settingsWindowIdentifier)", "@\(menuWindowIdentifier)"]
            )
        )

        XCTAssertEqual(state.appRunning, true)
        XCTAssertEqual(state.pid, 321)
        XCTAssertEqual(state.menuVisible, true)
        XCTAssertEqual(state.visibleWindows, ["@\(settingsWindowIdentifier)", "@\(menuWindowIdentifier)"])
        XCTAssertEqual(state.accessibilityTrusted, true)
    }
}

