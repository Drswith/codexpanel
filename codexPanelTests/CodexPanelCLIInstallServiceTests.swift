import XCTest

final class CodexPanelCLIInstallServiceTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexpanel-cli-install-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try super.tearDownWithError()
    }

    func testStatusReturnsHelperMissingWhenHelperDoesNotExist() {
        let helperURL = self.rootDirectory.appendingPathComponent("helpers/codexpanel")
        let installURL = self.rootDirectory.appendingPathComponent("bin/codexpanel")
        let service = CodexPanelCLIInstallService(
            installURL: installURL,
            helperURL: helperURL
        )

        guard case let .helperMissing(helperPath, installPath) = service.status() else {
            return XCTFail("expected helperMissing status")
        }
        XCTAssertEqual(helperPath, helperURL.path)
        XCTAssertEqual(installPath, installURL.path)
    }

    func testInstallSymlinkCreatesDirectoryAndLink() throws {
        let helperURL = self.rootDirectory.appendingPathComponent("helpers/codexpanel")
        let installURL = self.rootDirectory.appendingPathComponent("bin/codexpanel")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("dummy".utf8).write(to: helperURL)

        let service = CodexPanelCLIInstallService(
            installURL: installURL,
            helperURL: helperURL
        )
        let result = try service.installSymlink()

        XCTAssertEqual(result.installPath, installURL.path)
        XCTAssertEqual(result.helperPath, helperURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installURL.path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installURL.path),
            helperURL.path
        )
    }

    func testInstallSymlinkReplacesExistingPath() throws {
        let helperURL = self.rootDirectory.appendingPathComponent("helpers/codexpanel")
        let installURL = self.rootDirectory.appendingPathComponent("bin/codexpanel")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helperURL)

        try FileManager.default.createDirectory(
            at: installURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: installURL)

        let service = CodexPanelCLIInstallService(
            installURL: installURL,
            helperURL: helperURL
        )
        _ = try service.installSymlink()

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: installURL.path),
            helperURL.path
        )
    }

    func testStatusReturnsInstalledWithLinkedTarget() throws {
        let helperURL = self.rootDirectory.appendingPathComponent("helpers/codexpanel")
        let installURL = self.rootDirectory.appendingPathComponent("bin/codexpanel")
        try FileManager.default.createDirectory(
            at: helperURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("helper".utf8).write(to: helperURL)
        try FileManager.default.createDirectory(
            at: installURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: installURL.path,
            withDestinationPath: helperURL.path
        )

        let service = CodexPanelCLIInstallService(
            installURL: installURL,
            helperURL: helperURL
        )

        guard case let .installed(helperPath, installPath, linkedTarget) = service.status() else {
            return XCTFail("expected installed status")
        }
        XCTAssertEqual(helperPath, helperURL.path)
        XCTAssertEqual(installPath, installURL.path)
        XCTAssertEqual(linkedTarget, helperURL.path)
    }
}
