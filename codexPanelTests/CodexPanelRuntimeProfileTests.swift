import XCTest

final class CodexPanelRuntimeProfileTests: XCTestCase {
    private let defaultHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    func testDebugWithoutOverrideUsesDevHome() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.channel, .debug)
        XCTAssertEqual(profile.homeSource, .debugDefault)
        XCTAssertEqual(profile.homeRoot.path, "/Users/example/.codexpanel-dev/home")
        XCTAssertFalse(profile.usesRealHome)
    }

    func testDebugUsesDevIdentity() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.bundleIdentifier, "com.codexpanel.dev")
        XCTAssertEqual(profile.automationURLScheme, "codexpanel-dev")
        XCTAssertEqual(profile.oauthURLScheme, "com.codexpanel.dev.oauth")
        XCTAssertEqual(profile.cliCommandName, "codexpanel-dev")
    }

    func testDebugUsesDevNetworkPorts() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.network.oauthRedirectURI, "http://localhost:1555/auth/callback")
        XCTAssertEqual(profile.network.openAIAccountGatewayBaseURLString, "http://localhost:1556/v1")
        XCTAssertEqual(profile.network.openRouterGatewayBaseURLString, "http://localhost:1557/v1")
    }

    func testDebugRespectsExplicitHomeOverride() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [
                CodexPanelRuntimeProfile.homeOverrideEnvironmentKey: "/tmp/codexpanel-explicit-home",
            ],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.homeSource, .environmentOverride)
        XCTAssertEqual(profile.homeRoot.path, "/tmp/codexpanel-explicit-home")
        XCTAssertFalse(profile.usesRealHome)
    }

    func testDebugRequiresDangerSwitchForRealHome() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [
                CodexPanelRuntimeProfile.allowRealHomeEnvironmentKey: "1",
            ],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.homeSource, .realHome)
        XCTAssertEqual(profile.homeRoot.path, "/Users/example")
        XCTAssertTrue(profile.usesRealHome)
    }

    func testReleaseKeepsRealHomeByDefault() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .release,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.channel, .release)
        XCTAssertEqual(profile.homeSource, .realHome)
        XCTAssertEqual(profile.homeRoot.path, "/Users/example")
        XCTAssertTrue(profile.usesRealHome)
    }

    func testReleaseKeepsProductionIdentity() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .release,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.bundleIdentifier, "com.codexpanel")
        XCTAssertEqual(profile.automationURLScheme, "codexpanel")
        XCTAssertEqual(profile.oauthURLScheme, "com.codexpanel.oauth")
        XCTAssertEqual(profile.cliCommandName, "codexpanel")
    }

    func testReleaseKeepsProductionNetworkPorts() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .release,
            environment: [:],
            defaultHome: self.defaultHome
        )

        XCTAssertEqual(profile.network.oauthRedirectURI, "http://localhost:1455/auth/callback")
        XCTAssertEqual(profile.network.openAIAccountGatewayBaseURLString, "http://localhost:1456/v1")
        XCTAssertEqual(profile.network.openRouterGatewayBaseURLString, "http://localhost:1457/v1")
    }

    func testDebugHomeProducesCodexAndCodexPanelRootsAwayFromRealHome() {
        let profile = CodexPanelRuntimeProfile.resolve(
            channel: .debug,
            environment: [:],
            defaultHome: self.defaultHome
        )

        let codexRoot = profile.homeRoot.appendingPathComponent(".codex", isDirectory: true)
        let codexPanelRoot = profile.homeRoot.appendingPathComponent(".codexpanel", isDirectory: true)

        XCTAssertEqual(codexRoot.path, "/Users/example/.codexpanel-dev/home/.codex")
        XCTAssertEqual(codexPanelRoot.path, "/Users/example/.codexpanel-dev/home/.codexpanel")
        XCTAssertNotEqual(codexRoot.path, "/Users/example/.codex")
        XCTAssertNotEqual(codexPanelRoot.path, "/Users/example/.codexpanel")
    }
}
