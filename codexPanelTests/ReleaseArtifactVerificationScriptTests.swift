import Foundation
import XCTest

final class ReleaseArtifactVerificationScriptTests: XCTestCase {
    func testVerificationScriptPassesWithValidFixture() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testVerificationScriptFailsWhenUpdatesFieldMissing() throws {
        let fixture = try self.makeFixture(includeZipDownloadURL: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("release.artifacts.1.downloadURL"))
    }

    func testVerificationScriptFailsWhenLegacyCLIHelperIsBundled() throws {
        let fixture = try self.makeFixture(includeLegacyCLIHelper: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Legacy CLI helper must not be bundled"))
    }

    func testVerificationScriptFailsWhenLegacyAutomationSchemeIsRegistered() throws {
        let fixture = try self.makeFixture(includeLegacyAutomationScheme: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Legacy CLI automation URL scheme must not be registered"))
    }

    func testVerificationScriptFailsWhenMainExecutableMissing() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let mainBinaryPath = fixture.appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Codex Panel", isDirectory: false)
            .path
        try FileManager.default.removeItem(atPath: mainBinaryPath)

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("App executable missing"))
    }

    func testVerificationScriptFailsWhenTokscaleHelperIsBundled() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: "/bin/ls"),
            to: fixture.appBundleURL.appendingPathComponent("Contents/Helpers/tokscale")
        )

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("tokscale binary must not be bundled"))
    }

    func testVerificationScriptFailsWhenTokscaleSymlinkIsBundledInResources() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createSymbolicLink(
            atPath: fixture.appBundleURL.appendingPathComponent("Contents/Resources/tokscale").path,
            withDestinationPath: "/nonexistent/tokscale"
        )

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("tokscale binary must not be bundled"))
    }

    func testVerificationScriptFailsWhenTokscaleLicenseMissing() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.appBundleURL.appendingPathComponent("Contents/Resources/tokscale-LICENSE.txt"))

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("tokscale license missing"))
    }

    func testVerificationScriptFailsWhenTokscaleDownloadManifestDiffers() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manifestURL = fixture.appBundleURL.appendingPathComponent("Contents/Resources/tokscale-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        // 版本相同也不能接受下载来源或校验值被更改的清单。
        manifest["platforms"] = [:]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("tokscale download manifest does not match"))
    }

    func testVerificationScriptFailsWhenTokscaleDownloadManifestMissing() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(
            at: fixture.appBundleURL.appendingPathComponent("Contents/Resources/tokscale-manifest.json")
        )

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("tokscale download manifest missing"))
    }

    private func runVerificationScript(appURL: URL, distURL: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let scriptURL = self.repoRootURL()
            .appendingPathComponent("scripts", isDirectory: true)
            .appendingPathComponent("verify_release_artifacts.sh", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: scriptURL.path) else {
            throw XCTSkip("校验脚本不存在或不可执行: \(scriptURL.path)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, appURL.path, distURL.path]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }

    private func makeFixture(
        includeZipDownloadURL: Bool = true,
        includeLegacyCLIHelper: Bool = false,
        includeLegacyAutomationScheme: Bool = false
    ) throws -> (root: URL, appBundleURL: URL, distURL: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexpanel-release-verify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let appBundleURL = root.appendingPathComponent("Codex Panel.app", isDirectory: true)
        let mainBinaryDir = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let distURL = root.appendingPathComponent("dist", isDirectory: true)

        try fileManager.createDirectory(at: mainBinaryDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: distURL, withIntermediateDirectories: true)

        let mainBinaryURL = mainBinaryDir.appendingPathComponent("Codex Panel", isDirectory: false)
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: mainBinaryURL)

        let helperDirectory = appBundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
        let resourcesDirectory = appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try fileManager.createDirectory(at: helperDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resourcesDirectory, withIntermediateDirectories: true)
        try fileManager.copyItem(
            at: self.repoRootURL().appendingPathComponent("ThirdParty/tokscale/tokscale-LICENSE.txt"),
            to: resourcesDirectory.appendingPathComponent("tokscale-LICENSE.txt")
        )
        try fileManager.copyItem(
            at: self.repoRootURL().appendingPathComponent("ThirdParty/litellm/litellm-LICENSE.txt"),
            to: resourcesDirectory.appendingPathComponent("litellm-LICENSE.txt")
        )
        try fileManager.copyItem(
            at: self.repoRootURL().appendingPathComponent("ThirdParty/tokscale/tokscale-manifest.json"),
            to: resourcesDirectory.appendingPathComponent("tokscale-manifest.json")
        )

        let infoPlistURL = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        let legacySchemeEntry = includeLegacyAutomationScheme ? "<string>codexpanel</string>" : ""
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleURLTypes</key>
            <array>
                <dict>
                    <key>CFBundleURLSchemes</key>
                    <array>
                        <string>com.codexpanel.oauth</string>
                        \(legacySchemeEntry)
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """
        try infoPlist.write(to: infoPlistURL, atomically: true, encoding: .utf8)

        if includeLegacyCLIHelper {
            try fileManager.copyItem(
                at: URL(fileURLWithPath: "/bin/ls"),
                to: helperDirectory.appendingPathComponent("codexpanel", isDirectory: false)
            )
        }

        let updatesJSONURL = distURL.appendingPathComponent("updates.json", isDirectory: false)
        let updatesJSON = """
        {
          "schemaVersion": 1,
          "channel": "stable",
          "release": {
            "version": "1.4.2",
            "artifacts": [
              {
                "architecture": "universal",
                "format": "dmg",
                "downloadURL": "https://example.invalid/codexpanel-1.4.2-macOS.dmg",
                "sha256": "dmg-sha"
              },
              {
                "architecture": "universal",
                "format": "zip",
                \(includeZipDownloadURL ? "\"downloadURL\": \"https://example.invalid/codexpanel-1.4.2-macOS.zip\"," : "")
                "sha256": "zip-sha"
              }
            ]
          }
        }
        """
        try updatesJSON.write(to: updatesJSONURL, atomically: true, encoding: .utf8)

        return (root, appBundleURL, distURL)
    }

    private func repoRootURL(filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath, isDirectory: false)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
