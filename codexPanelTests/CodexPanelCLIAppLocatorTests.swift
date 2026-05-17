import Foundation
import XCTest

final class CodexPanelCLIAppLocatorTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexpanel-cli-app-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.rootDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory {
            try? FileManager.default.removeItem(at: rootDirectory)
        }
        try super.tearDownWithError()
    }

    func testHelperOwningAppURLResolvesBundledHelperPath() throws {
        let appURL = try self.makeAppBundle(bundleIdentifier: "com.codexpanel.dev")
        let helperURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("codexpanel-dev", isDirectory: false)
        try self.writeExecutableStub(at: helperURL)

        let locator = CodexPanelAppLocator(
            identity: .debug,
            executablePathProvider: { helperURL.path }
        )

        XCTAssertEqual(locator.helperOwningAppURL(), appURL)
        XCTAssertEqual(locator.preferredRoutingAppURL(), appURL)
    }

    func testHelperOwningAppURLResolvesSymlinkedHelperPath() throws {
        let appURL = try self.makeAppBundle(bundleIdentifier: "com.codexpanel.dev")
        let helperURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("codexpanel-dev", isDirectory: false)
        try self.writeExecutableStub(at: helperURL)

        let binURL = self.rootDirectory
            .appendingPathComponent("home", isDirectory: true)
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let symlinkURL = binURL.appendingPathComponent("codexpanel-dev", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: helperURL)

        let locator = CodexPanelAppLocator(
            identity: .debug,
            executablePathProvider: { symlinkURL.path }
        )

        XCTAssertEqual(locator.helperOwningAppURL(), appURL)
        XCTAssertEqual(locator.preferredRoutingAppURL(), appURL)
    }

    func testPreferredRoutingAppURLRejectsMismatchedBundleIdentifier() throws {
        let identity = CLIRuntimeIdentity(
            commandName: "codexpanel-test",
            bundleIdentifier: "com.codexpanel.test",
            urlScheme: "codexpanel-test"
        )
        let appURL = try self.makeAppBundle(bundleIdentifier: "com.codexpanel.other")
        let helperURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("codexpanel-test", isDirectory: false)
        try self.writeExecutableStub(at: helperURL)

        let locator = CodexPanelAppLocator(
            identity: identity,
            executablePathProvider: { helperURL.path }
        )

        XCTAssertEqual(locator.helperOwningAppURL(), appURL)
        XCTAssertNil(locator.preferredRoutingAppURL())
    }

    private func makeAppBundle(bundleIdentifier: String) throws -> URL {
        let appURL = self.rootDirectory.appendingPathComponent("Codex Panel DEV.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: contentsURL.appendingPathComponent("Helpers", isDirectory: true),
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": "1.0.0",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        return appURL
    }

    private func writeExecutableStub(at url: URL) throws {
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: url.path
        )
    }
}
