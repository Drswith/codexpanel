import XCTest

@MainActor
final class CodexPanelUICommandRouterTests: XCTestCase {
    func testParseOAuthLoginURLFromHost() throws {
        let url = try XCTUnwrap(URL(string: "com.codexpanel.oauth://login"))
        guard case .oauthLogin = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected oauthLogin command")
        }
    }

    func testParseOAuthLoginURLFromPath() throws {
        let url = try XCTUnwrap(URL(string: "com.codexpanel.oauth:///login"))
        guard case .oauthLogin = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected oauthLogin command")
        }
    }

    func testParseOpenSettingsURLWithPage() throws {
        let url = try XCTUnwrap(URL(string: "codexpanel://view/open/settings?page=usage"))
        guard case .view(let command) = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected view command")
        }
        XCTAssertEqual(command.action, .open)
        XCTAssertEqual(command.target, .settings)
        XCTAssertEqual(command.settingsPage, .usage)
    }

    func testParseOpenSettingsURLFallsBackToAccountsPage() throws {
        let url = try XCTUnwrap(URL(string: "codexpanel://view/open/settings?page=invalid"))
        guard case .view(let command) = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected view command")
        }
        XCTAssertEqual(command.action, .open)
        XCTAssertEqual(command.target, .settings)
        XCTAssertEqual(command.settingsPage, .accounts)
    }

    func testParseOpenSettingsURLWithoutPageDefaultsToAccounts() throws {
        let url = try XCTUnwrap(URL(string: "codexpanel://view/open/settings"))
        guard case .view(let command) = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected view command")
        }
        XCTAssertEqual(command.action, .open)
        XCTAssertEqual(command.target, .settings)
        XCTAssertEqual(command.settingsPage, .accounts)
    }

    func testParseLegacyUpdatesPageMapsToAbout() throws {
        let url = try XCTUnwrap(URL(string: "codexpanel://view/open/settings?page=updates"))
        guard case .view(let command) = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected view command")
        }
        XCTAssertEqual(command.action, .open)
        XCTAssertEqual(command.target, .settings)
        XCTAssertEqual(command.settingsPage, .about)
    }

    func testParseCloseAllURL() throws {
        let url = try XCTUnwrap(URL(string: "codexpanel://view/close/all"))
        guard case .view(let command) = CodexPanelURLCommandParser.parse(url) else {
            return XCTFail("expected view command")
        }
        XCTAssertEqual(command.action, .close)
        XCTAssertEqual(command.target, .all)
        XCTAssertNil(command.settingsPage)
    }

    func testHandleOpenAllThrowsUnsupportedCommand() throws {
        let command = CodexPanelURLCommand.view(
            CodexPanelViewCommand(
                action: .open,
                target: .all,
                settingsPage: nil
            )
        )
        let router = CodexPanelUICommandRouter()

        XCTAssertThrowsError(try router.handle(command)) { error in
            guard let routeError = error as? CodexPanelUIRouteError else {
                return XCTFail("expected CodexPanelUIRouteError, got \(error)")
            }
            XCTAssertEqual(routeError, .unsupportedCommand)
        }
    }

    func testHandleOpenSettingsRoutesToPresenterWithSpecifiedPage() throws {
        let recorder = RouterCallRecorder()
        let router = CodexPanelUICommandRouter(handlers: recorder.handlers())
        let command = CodexPanelURLCommand.view(
            CodexPanelViewCommand(
                action: .open,
                target: .settings,
                settingsPage: .usage
            )
        )

        try router.handle(command)

        XCTAssertEqual(recorder.openedSettingsPages, [.usage])
        XCTAssertEqual(recorder.requestCloseMenuCount, 1)
    }

    func testHandleOpenSettingsDefaultsToAccountsWhenPageIsNil() throws {
        let recorder = RouterCallRecorder()
        let router = CodexPanelUICommandRouter(handlers: recorder.handlers())
        let command = CodexPanelURLCommand.view(
            CodexPanelViewCommand(
                action: .open,
                target: .settings,
                settingsPage: nil
            )
        )

        try router.handle(command)

        XCTAssertEqual(recorder.openedSettingsPages, [.accounts])
        XCTAssertEqual(recorder.requestCloseMenuCount, 1)
    }

    func testHandleMenuRoutesInvokeMenuHandlers() throws {
        let recorder = RouterCallRecorder()
        let router = CodexPanelUICommandRouter(handlers: recorder.handlers())

        try router.handle(.view(.init(action: .open, target: .menu, settingsPage: nil)))
        try router.handle(.view(.init(action: .close, target: .menu, settingsPage: nil)))

        XCTAssertEqual(recorder.openMenuCount, 1)
        XCTAssertEqual(recorder.closeMenuCount, 1)
        XCTAssertEqual(recorder.requestCloseMenuCount, 0)
    }

    func testHandleLoginRoutesInvokeLoginHandlers() throws {
        let recorder = RouterCallRecorder()
        let router = CodexPanelUICommandRouter(handlers: recorder.handlers())

        try router.handle(.view(.init(action: .open, target: .login, settingsPage: nil)))
        try router.handle(.view(.init(action: .close, target: .login, settingsPage: nil)))

        XCTAssertEqual(recorder.openLoginCount, 1)
        XCTAssertEqual(recorder.closeLoginCount, 1)
        XCTAssertEqual(recorder.requestCloseMenuCount, 1)
    }

    func testHandleCloseAllRoutesInvokeAllCloseHandlers() throws {
        let recorder = RouterCallRecorder()
        let router = CodexPanelUICommandRouter(handlers: recorder.handlers())
        let command = CodexPanelURLCommand.view(
            CodexPanelViewCommand(
                action: .close,
                target: .all,
                settingsPage: nil
            )
        )

        try router.handle(command)

        XCTAssertEqual(recorder.closeSettingsCount, 1)
        XCTAssertEqual(recorder.closeMenuCount, 1)
        XCTAssertEqual(recorder.closeLoginCount, 1)
    }
}

private final class RouterCallRecorder {
    var openedSettingsPages: [SettingsPage] = []
    var closeSettingsCount = 0
    var openMenuCount = 0
    var closeMenuCount = 0
    var openLoginCount = 0
    var closeLoginCount = 0
    var requestCloseMenuCount = 0

    func handlers() -> CodexPanelUICommandRouterHandlers {
        CodexPanelUICommandRouterHandlers(
            openSettings: { [weak self] page in
                self?.openedSettingsPages.append(page)
            },
            closeSettings: { [weak self] in
                self?.closeSettingsCount += 1
            },
            openMenu: { [weak self] in
                self?.openMenuCount += 1
            },
            closeMenu: { [weak self] in
                self?.closeMenuCount += 1
            },
            openLogin: { [weak self] in
                self?.openLoginCount += 1
            },
            closeLogin: { [weak self] in
                self?.closeLoginCount += 1
            },
            requestCloseMenu: { [weak self] in
                self?.requestCloseMenuCount += 1
            }
        )
    }
}
