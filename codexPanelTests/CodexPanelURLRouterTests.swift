import XCTest

@MainActor
final class CodexPanelURLRouterTests: XCTestCase {
    private let defaultHome = URL(fileURLWithPath: "/Users/example", isDirectory: true)

    func testReleaseOAuthLoginURLSupportsHostAndPathForms() throws {
        let profile = self.profile(channel: .release)
        let hostURL = try XCTUnwrap(URL(string: "com.codexpanel.oauth://login"))
        let pathURL = try XCTUnwrap(URL(string: "com.codexpanel.oauth:///login"))

        XCTAssertTrue(CodexPanelURLRouter.isLoginURL(hostURL, profile: profile))
        XCTAssertTrue(CodexPanelURLRouter.isLoginURL(pathURL, profile: profile))
    }

    func testDebugOAuthLoginURLUsesDevelopmentScheme() throws {
        let profile = self.profile(channel: .debug)
        let debugURL = try XCTUnwrap(URL(string: "com.codexpanel.dev.oauth://login"))
        let releaseURL = try XCTUnwrap(URL(string: "com.codexpanel.oauth://login"))

        XCTAssertTrue(CodexPanelURLRouter.isLoginURL(debugURL, profile: profile))
        XCTAssertFalse(CodexPanelURLRouter.isLoginURL(releaseURL, profile: profile))
    }

    func testNonOAuthURLsAreRejected() throws {
        let profile = self.profile(channel: .release)
        let formerAutomationURL = try XCTUnwrap(URL(string: "codexpanel://view/open/settings"))
        let unrelatedOAuthPath = try XCTUnwrap(URL(string: "com.codexpanel.oauth://settings"))

        XCTAssertFalse(CodexPanelURLRouter.isLoginURL(formerAutomationURL, profile: profile))
        XCTAssertFalse(CodexPanelURLRouter.isLoginURL(unrelatedOAuthPath, profile: profile))
    }

    private func profile(channel: CodexPanelRuntimeChannel) -> CodexPanelRuntimeProfile {
        CodexPanelRuntimeProfile.resolve(
            channel: channel,
            environment: [:],
            defaultHome: self.defaultHome
        )
    }
}
