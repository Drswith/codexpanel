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
