import XCTest

final class CodexPanelCLISnapshotWindowSelectionCoreTests: XCTestCase {
    func testClassifyWindowUsesIdentifierFirst() {
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(
                identifier: settingsWindowIdentifier,
                title: "Anything"
            ),
            .settings
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(
                identifier: loginWindowIdentifier,
                title: "Anything"
            ),
            .login
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(
                identifier: menuWindowIdentifier,
                title: "Anything"
            ),
            .menu
        )
    }

    func testClassifyWindowFallsBackToTitleWhenIdentifierMissing() {
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(identifier: nil, title: "OpenAI Settings"),
            .settings
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(identifier: nil, title: "OAuth Login"),
            .login
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.classifyWindow(identifier: nil, title: "Random Window"),
            .all
        )
    }

    func testSelectWindowIndicesForExplicitTarget() {
        let windows = self.fixtureWindows()

        XCTAssertEqual(CLISnapshotWindowSelectionCore.selectWindowIndices(windows, target: .settings), [1])
        XCTAssertEqual(CLISnapshotWindowSelectionCore.selectWindowIndices(windows, target: .menu), [2])
        XCTAssertEqual(CLISnapshotWindowSelectionCore.selectWindowIndices(windows, target: .login), [3])
        XCTAssertEqual(CLISnapshotWindowSelectionCore.selectWindowIndices(windows, target: .all), [0, 1, 2, 3])
    }

    func testAutoSelectionPrefersSettingsThenMenuThenLogin() {
        let withSettings = self.fixtureWindows()
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.selectWindowIndices(withSettings, target: .auto),
            [1]
        )

        let withMenu = [
            CLISnapshotWindowMetadata(identifier: nil, title: "A", kind: .all),
            CLISnapshotWindowMetadata(identifier: nil, title: "Menu", kind: .menu),
        ]
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.selectWindowIndices(withMenu, target: .auto),
            [1]
        )

        let withLogin = [
            CLISnapshotWindowMetadata(identifier: nil, title: "A", kind: .all),
            CLISnapshotWindowMetadata(identifier: nil, title: "Login", kind: .login),
        ]
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.selectWindowIndices(withLogin, target: .auto),
            [1]
        )
    }

    func testAutoSelectionFallsBackToAllWindowsWhenNoPreferredKinds() {
        let windows = [
            CLISnapshotWindowMetadata(identifier: nil, title: "A", kind: .all),
            CLISnapshotWindowMetadata(identifier: nil, title: "B", kind: .all),
        ]
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.selectWindowIndices(windows, target: .auto),
            [0, 1]
        )
    }

    func testAutoResolvedTargetMatchesPreferredPriority() {
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.autoResolvedTarget(for: self.fixtureWindows()),
            .settings
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.autoResolvedTarget(for: [
                CLISnapshotWindowMetadata(identifier: nil, title: nil, kind: .menu),
                CLISnapshotWindowMetadata(identifier: nil, title: nil, kind: .login),
            ]),
            .menu
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.autoResolvedTarget(for: [
                CLISnapshotWindowMetadata(identifier: nil, title: nil, kind: .login),
            ]),
            .login
        )
        XCTAssertEqual(
            CLISnapshotWindowSelectionCore.autoResolvedTarget(for: [
                CLISnapshotWindowMetadata(identifier: nil, title: nil, kind: .all),
            ]),
            .all
        )
    }

    private func fixtureWindows() -> [CLISnapshotWindowMetadata] {
        [
            CLISnapshotWindowMetadata(identifier: nil, title: "General", kind: .all),
            CLISnapshotWindowMetadata(identifier: settingsWindowIdentifier, title: "Settings", kind: .settings),
            CLISnapshotWindowMetadata(identifier: menuWindowIdentifier, title: "Menu", kind: .menu),
            CLISnapshotWindowMetadata(identifier: loginWindowIdentifier, title: "Login", kind: .login),
        ]
    }
}
