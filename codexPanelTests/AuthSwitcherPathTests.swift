import XCTest

final class AuthSwitcherPathTests: CodexPanelTestCase {
    func testAuthSwitcherWritesThroughCodexPathsAuthURL() throws {
        let account = try self.makeOAuthAccount(
            accountID: "acct_profile_path",
            email: "profile@example.com"
        )

        try AuthSwitcher.activate(account)

        XCTAssertTrue(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
        XCTAssertEqual(AuthSwitcher.authFilePath, CodexPaths.authURL)
        XCTAssertTrue(CodexPaths.authURL.path.contains("/.codex/auth.json"))
        XCTAssertTrue(CodexPaths.authURL.path.hasPrefix(CodexPaths.realHome.path))
    }
}
