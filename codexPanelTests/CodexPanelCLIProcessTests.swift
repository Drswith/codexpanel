import Foundation
import XCTest

final class CodexPanelCLIProcessTests: XCTestCase {
    func testViewOpenAllReturnsRouteUnsupportedJSONError() throws {
        let result = try self.runCLI(arguments: ["view", "open", "all", "--json"])
        XCTAssertEqual(result.status, 6)

        let payload = try self.parseJSONObject(result.stdout)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 6)
        XCTAssertNotNil(error["message"] as? String)
    }

    func testInvalidWaitReturnsArgumentErrorWithStableJSONShape() throws {
        let result = try self.runCLI(arguments: ["view", "open", "settings", "--wait", "-1", "--json"])
        XCTAssertEqual(result.status, 2)

        let payload = try self.parseJSONObject(result.stdout)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 2)
        XCTAssertNotNil(error["message"] as? String)
        XCTAssertTrue(error.keys.contains("hint"))
    }

    func testPageOptionOutsideSettingsReturnsArgumentError() throws {
        let result = try self.runCLI(arguments: ["view", "open", "menu", "--page", "usage", "--json"])
        XCTAssertEqual(result.status, 2)

        let payload = try self.parseJSONObject(result.stdout)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 2)
    }

    func testUnknownViewOptionReturnsArgumentErrorJSON() throws {
        let result = try self.runCLI(arguments: ["view", "open", "settings", "--json", "--unknown"])
        XCTAssertEqual(result.status, 2)

        let payload = try self.parseJSONObject(result.stdout)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 2)
        XCTAssertNotNil(error["message"] as? String)
    }

    func testStateUnknownOptionReturnsArgumentErrorJSON() throws {
        let result = try self.runCLI(arguments: ["state", "--invalid"])
        XCTAssertEqual(result.status, 2)

        let payload = try self.parseJSONObject(result.stdout)
        let error = try XCTUnwrap(payload["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, 2)
        XCTAssertTrue(error.keys.contains("message"))
    }

    func testUnknownTopLevelCommandReturnsArgumentErrorOnStderr() throws {
        let result = try self.runCLI(arguments: ["unknown-command"])
        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stdout.isEmpty)
        XCTAssertTrue(result.stderr.contains("Unknown command"))
    }

    func testStateDefaultsToJSONOutput() throws {
        let result = try self.runCLI(arguments: ["state"])
        XCTAssertEqual(result.status, 0)

        let payload = try self.parseJSONObject(result.stdout)
        XCTAssertNotNil(payload["appRunning"] as? Bool)
        XCTAssertNotNil(payload["menuVisible"] as? Bool)
        XCTAssertNotNil(payload["accessibilityTrusted"] as? Bool)
    }

    func testDoctorDefaultsToJSONOutput() throws {
        let result = try self.runCLI(arguments: ["doctor"])
        XCTAssertEqual(result.status, 0)

        let payload = try self.parseJSONObject(result.stdout)
        XCTAssertNotNil(payload["appRunning"] as? Bool)
        XCTAssertNotNil(payload["helperBundled"] as? Bool)
        XCTAssertNotNil(payload["cliSymlinkPath"] as? String)
    }

    private func runCLI(arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let cliURL = try self.locateCLIExecutable()

        let process = Process()
        process.executableURL = cliURL
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout.trimmingCharacters(in: .whitespacesAndNewlines), stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func locateCLIExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let productsDir = ProcessInfo.processInfo.environment["BUILT_PRODUCTS_DIR"] {
            let root = URL(fileURLWithPath: productsDir, isDirectory: true)
            candidates.append(root.appendingPathComponent("codexpanel"))
            candidates.append(root.appendingPathComponent("Codex Panel DEV.app/Contents/Helpers/codexpanel"))
            candidates.append(root.appendingPathComponent("Codex Panel.app/Contents/Helpers/codexpanel"))
        }

        let testBundleRoot = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        candidates.append(testBundleRoot.appendingPathComponent("codexpanel"))
        candidates.append(testBundleRoot.appendingPathComponent("Codex Panel DEV.app/Contents/Helpers/codexpanel"))
        candidates.append(testBundleRoot.appendingPathComponent("Codex Panel.app/Contents/Helpers/codexpanel"))

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path), fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw XCTSkip("未找到可执行的 codexpanel CLI，候选路径: \(candidates.map(\.path).joined(separator: ", "))")
    }

    private func parseJSONObject(_ source: String) throws -> [String: Any] {
        let data = try XCTUnwrap(source.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
