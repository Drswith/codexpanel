import XCTest

final class CodexPanelCLIArgumentParserCoreTests: XCTestCase {
    func testViewOpenSettingsDefaultsToAccountsPage() throws {
        let command = try CLIArgumentParser.parse(arguments: ["view", "open", "settings"])
        guard case .view(let viewCommand) = command else {
            return XCTFail("Expected view command")
        }

        XCTAssertEqual(viewCommand.action, .open)
        XCTAssertEqual(viewCommand.target, .settings)
        XCTAssertEqual(viewCommand.page, .accounts)
        XCTAssertNil(viewCommand.waitSeconds)
        XCTAssertEqual(viewCommand.jsonOutput, false)
    }

    func testLegacyUpdatesPageMapsToAbout() throws {
        let command = try CLIArgumentParser.parse(arguments: ["view", "open", "settings", "--page", "updates"])
        guard case .view(let viewCommand) = command else {
            return XCTFail("Expected view command")
        }

        XCTAssertEqual(viewCommand.action, .open)
        XCTAssertEqual(viewCommand.target, .settings)
        XCTAssertEqual(viewCommand.page, .about)
    }

    func testPageOptionOnlyAllowedForOpenSettings() {
        XCTAssertThrowsError(
            try CLIArgumentParser.parse(arguments: ["view", "open", "menu", "--page", "usage", "--json"])
        ) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, .invalidArguments)
            XCTAssertEqual(cliError?.jsonOutput, true)
        }
    }

    func testViewOpenAllReturnsRouteUnsupported() {
        XCTAssertThrowsError(
            try CLIArgumentParser.parse(arguments: ["view", "open", "all", "--json"])
        ) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, .routeUnsupported)
            XCTAssertEqual(cliError?.jsonOutput, true)
        }
    }

    func testInvalidWaitReturnsInvalidArguments() {
        XCTAssertThrowsError(
            try CLIArgumentParser.parse(arguments: ["view", "open", "settings", "--wait", "-1"])
        ) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, .invalidArguments)
        }
    }

    func testUnknownTopLevelCommandReturnsInvalidArguments() {
        XCTAssertThrowsError(
            try CLIArgumentParser.parse(arguments: ["invalid-command"])
        ) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, .invalidArguments)
            XCTAssertTrue(cliError?.message.contains("Unknown command") == true)
        }
    }

    func testUnknownViewOptionReturnsInvalidArguments() {
        XCTAssertThrowsError(
            try CLIArgumentParser.parse(arguments: ["view", "open", "settings", "--unknown"])
        ) { error in
            let cliError = error as? CLIError
            XCTAssertEqual(cliError?.code, .invalidArguments)
            XCTAssertTrue(cliError?.message.contains("Unknown option for view") == true)
        }
    }

    func testStateDefaultsToJSONOutput() throws {
        let command = try CLIArgumentParser.parse(arguments: ["state"])
        guard case .state(let stateCommand) = command else {
            return XCTFail("Expected state command")
        }
        XCTAssertEqual(stateCommand.jsonOutput, true)
    }

    func testDoctorDefaultsToJSONOutput() throws {
        let command = try CLIArgumentParser.parse(arguments: ["doctor"])
        guard case .doctor(let doctorCommand) = command else {
            return XCTFail("Expected doctor command")
        }
        XCTAssertEqual(doctorCommand.jsonOutput, true)
    }
}
