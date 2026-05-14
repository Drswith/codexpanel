import AppKit
import ApplicationServices
import Foundation
import XCTest

final class CodexPanelCLIAccessibilityIntegrationTests: XCTestCase {
    func testSnapshotJSONWhenAccessibilityReady() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("未授予 Accessibility 权限，跳过真实 AX 集成测试。")
        }

        guard NSRunningApplication.runningApplications(withBundleIdentifier: codexPanelBundleIdentifier).isEmpty == false else {
            throw XCTSkip("Codex Panel 未运行，跳过真实 AX 集成测试。")
        }

        let result = try self.runCLI(arguments: ["snapshot", "--format", "json", "--target", "auto"])
        XCTAssertEqual(result.status, 0, "snapshot 命令执行失败: \(result.stderr)")

        let payload = try self.parseJSONObject(result.stdout)
        XCTAssertEqual(payload["bundleIdentifier"] as? String, codexPanelBundleIdentifier)
        XCTAssertNotNil(payload["pid"] as? NSNumber)
        XCTAssertNotNil(payload["target"] as? String)
        XCTAssertNotNil(payload["windows"] as? [Any])
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

        return (
            process.terminationStatus,
            stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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
