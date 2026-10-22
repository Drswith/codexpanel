import Foundation
import Darwin
import XCTest

final class TokscaleProcessRunnerTests: CodexPanelTestCase {
    private func request(_ script: String, timeout: TimeInterval = 2, maximumOutputBytes: Int = 1_024) throws -> TokscaleProcessRequest {
        let root = CodexPaths.codexBarRoot.appendingPathComponent("runner-tests")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return TokscaleProcessRequest(executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], workingDirectoryURL: root, timeout: timeout, maximumOutputBytes: maximumOutputBytes, maximumErrorBytes: 1_024)
    }

    func testCapturesOutputAndDoesNotLeaveTransientFiles() throws {
        let request = try self.request("printf '{\"ok\":true}'")
        let data = try TokscaleProcessRunner().run(request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workingDirectoryURL.path), [])
    }

    func testNonZeroExitIsReportedWithoutExposingStderr() throws {
        XCTAssertThrowsError(try TokscaleProcessRunner().run(self.request("printf 'private diagnostic' >&2; exit 17"))) { error in
            XCTAssertEqual(error as? TokscaleError, .processFailed(17))
            XCTAssertFalse(error.localizedDescription.contains("private diagnostic"))
        }
    }

    func testTimeoutTerminatesAndReapsProcess() throws {
        let started = Date()
        let request = try self.request("exec /bin/sleep 30", timeout: 0.05)
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in
            XCTAssertEqual(error as? TokscaleError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workingDirectoryURL.path), [])
    }

    func testTimeoutKillsProcessThatIgnoresTermination() throws {
        let started = Date()
        let request = try self.request("trap '' TERM; while :; do :; done", timeout: 0.05)
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in
            XCTAssertEqual(error as? TokscaleError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: request.workingDirectoryURL.path), [])
    }

    func testTimeoutAlsoTerminatesWrapperChildProcess() throws {
        let request = try self.request("trap '' TERM; /bin/sleep 30 & echo $! > child.pid; wait", timeout: 0.1)
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in XCTAssertEqual(error as? TokscaleError, .timedOut) }
        let pidText = try String(contentsOf: request.workingDirectoryURL.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pid = try XCTUnwrap(Int32(pidText))
        defer { kill(pid, SIGKILL) }
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
        XCTAssertEqual(kill(pid, 0), -1, "wrapper 的原生子进程必须同时退出")
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellationTerminatesWrapperAndChildBeforeTimeout() throws {
        var request = try self.request("trap '' TERM; /bin/sleep 30 & echo $! > child.pid; wait", timeout: 10)
        let pidURL = request.workingDirectoryURL.appendingPathComponent("child.pid")
        request.shouldCancel = { FileManager.default.fileExists(atPath: pidURL.path) }
        let started = Date()
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in XCTAssertEqual(error as? TokscaleError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let pid = try XCTUnwrap(Int32(try String(contentsOf: pidURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { kill(pid, SIGKILL) }
        for _ in 0..<100 where kill(pid, 0) == 0 { usleep(10_000) }
        XCTAssertEqual(kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOutputLimitTerminatesWriterInsteadOfBlockingOnPipe() throws {
        let request = try self.request("while :; do printf '012345678901234567890123456789'; done", maximumOutputBytes: 128)
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in
            XCTAssertEqual(error as? TokscaleError, .outputTooLarge)
        }
    }

    func testStderrLimitIsEnforcedSeparately() throws {
        let request = try self.request("while :; do printf '012345678901234567890123456789' >&2; done")
        XCTAssertThrowsError(try TokscaleProcessRunner().run(request)) { error in
            XCTAssertEqual(error as? TokscaleError, .outputTooLarge)
        }
    }
}
