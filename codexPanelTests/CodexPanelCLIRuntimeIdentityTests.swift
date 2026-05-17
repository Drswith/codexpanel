import XCTest

final class CodexPanelCLIRuntimeIdentityTests: XCTestCase {
    func testDebugIdentityUsesDevCommandBundleAndScheme() {
        XCTAssertEqual(CLIRuntimeIdentity.debug.commandName, "codexpanel-dev")
        XCTAssertEqual(CLIRuntimeIdentity.debug.bundleIdentifier, "com.codexpanel.dev")
        XCTAssertEqual(CLIRuntimeIdentity.debug.urlScheme, "codexpanel-dev")
    }

    func testReleaseIdentityUsesProductionCommandBundleAndScheme() {
        XCTAssertEqual(CLIRuntimeIdentity.release.commandName, "codexpanel")
        XCTAssertEqual(CLIRuntimeIdentity.release.bundleIdentifier, "com.codexpanel")
        XCTAssertEqual(CLIRuntimeIdentity.release.urlScheme, "codexpanel")
    }

    func testViewURLBuilderUsesIdentityScheme() throws {
        let command = ViewCommand(
            action: .open,
            target: .settings,
            page: .usage,
            waitSeconds: nil,
            jsonOutput: true
        )

        XCTAssertEqual(
            CLIViewURLBuilder.makeViewURL(command: command, identity: .debug)?.absoluteString,
            "codexpanel-dev://view/open/settings?page=usage"
        )
        XCTAssertEqual(
            CLIViewURLBuilder.makeViewURL(command: command, identity: .release)?.absoluteString,
            "codexpanel://view/open/settings?page=usage"
        )
    }

    func testUsageTextCanRenderDevCommandName() {
        let usage = CLIUsage.text(commandName: "codexpanel-dev")

        XCTAssertTrue(usage.contains("codexpanel-dev view open settings"))
        XCTAssertFalse(usage.contains("codexpanel view open settings"))
    }
}
