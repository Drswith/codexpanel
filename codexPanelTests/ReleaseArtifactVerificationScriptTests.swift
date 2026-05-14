import Foundation
import XCTest

final class ReleaseArtifactVerificationScriptTests: XCTestCase {
    func testVerificationScriptPassesWithValidFixture() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testVerificationScriptFailsWhenHelperMissing() throws {
        let fixture = try self.makeFixture(includeHelper: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Bundled CLI helper missing"))
    }

    func testVerificationScriptFailsWhenUpdatesFieldMissing() throws {
        let fixture = try self.makeFixture(includeZipDownloadURL: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("release.artifacts.1.downloadURL"))
    }

    func testVerificationScriptFailsWhenHelperNotExecutable() throws {
        let fixture = try self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let helperPath = fixture.appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("codexpanel", isDirectory: false)
            .path
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o644))],
            ofItemAtPath: helperPath
        )

        let result = try self.runVerificationScript(appURL: fixture.appBundleURL, distURL: fixture.distURL)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("not executable"))
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
        includeHelper: Bool = true,
        includeZipDownloadURL: Bool = true
    ) throws -> (root: URL, appBundleURL: URL, distURL: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("codexpanel-release-verify-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let appBundleURL = root.appendingPathComponent("Codex Panel.app", isDirectory: true)
        let mainBinaryDir = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let helperDir = appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
        let distURL = root.appendingPathComponent("dist", isDirectory: true)

        try fileManager.createDirectory(at: mainBinaryDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: distURL, withIntermediateDirectories: true)

        let mainBinaryURL = mainBinaryDir.appendingPathComponent("Codex Panel", isDirectory: false)
        try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: mainBinaryURL)

        if includeHelper {
            try fileManager.createDirectory(at: helperDir, withIntermediateDirectories: true)
            let helperBinaryURL = helperDir.appendingPathComponent("codexpanel", isDirectory: false)
            try fileManager.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: helperBinaryURL)
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
