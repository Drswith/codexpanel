import Foundation
import Darwin

nonisolated struct TokscaleProcessRequest: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectoryURL: URL
    let timeout: TimeInterval
    var maximumOutputBytes: Int = 32 * 1_024 * 1_024
    var maximumErrorBytes: Int = 256 * 1_024
    var shouldCancel: @Sendable () -> Bool = { false }
}

nonisolated enum TokscaleError: LocalizedError, Equatable {
    case helperMissing
    case launchFailed
    case timedOut
    case cancelled
    case outputTooLarge
    case processFailed(Int32)
    case invalidReport
    case pricingSeedMissing
    case engineNotSelected
    case incompatibleVersion(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing: return "选中的 tokscale 已不可用，请重新检测或下载。"
        case .launchFailed: return "无法启动用量统计程序。"
        case .timedOut: return "用量统计超时，请稍后重试。"
        case .cancelled: return "用量统计已取消。"
        case .outputTooLarge: return "用量统计结果超过大小限制。"
        case .processFailed(let status): return "用量统计程序退出，状态码 \(status)。"
        case .invalidReport: return "用量统计返回了无效数据。"
        case .pricingSeedMissing: return "应用内的离线价格数据缺失，请重新安装完整应用。"
        case .engineNotSelected: return "请先选择已安装的 tokscale，或下载 Codex Panel 管理的副本。"
        case .incompatibleVersion(let version): return "tokscale \(version) 不兼容；需要 4.20.0 或更新的 4.x 版本。"
        }
    }
}

nonisolated protocol TokscaleProcessRunning: Sendable {
    func run(_ request: TokscaleProcessRequest) throws -> Data
}

/// 文件重定向避免 stdout/stderr 管道塞满造成死锁；结果限额与超时均有界。
nonisolated struct TokscaleProcessRunner: TokscaleProcessRunning {
    func run(_ request: TokscaleProcessRequest) throws -> Data {
        guard !request.shouldCancel() else { throw TokscaleError.cancelled }
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: request.executableURL.path) else {
            throw TokscaleError.helperMissing
        }
        let capture = request.workingDirectoryURL.appendingPathComponent("run-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: capture, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: capture) }
        let stdoutURL = capture.appendingPathComponent("stdout")
        let stderrURL = capture.appendingPathComponent("stderr")
        guard manager.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              manager.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw TokscaleError.launchFailed
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stdout.close(); try? stderr.close() }

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = request.arguments
        process.environment = request.environment
        process.currentDirectoryURL = request.workingDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { throw TokscaleError.launchFailed }
        // Foundation 为子进程建立独立组；npm/Node wrapper 的原生后代也须一起终止。
        let processGroup: pid_t? = getpgid(process.processIdentifier) == process.processIdentifier ? process.processIdentifier : nil

        let deadline = DispatchTime.now() + max(0.01, request.timeout)
        var failure: TokscaleError?
        while exited.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if request.shouldCancel() {
                failure = .cancelled
                break
            }
            if Self.size(stdoutURL) > request.maximumOutputBytes || Self.size(stderrURL) > request.maximumErrorBytes {
                failure = .outputTooLarge
                break
            }
            if DispatchTime.now() >= deadline {
                failure = .timedOut
                break
            }
        }
        if failure == nil, request.shouldCancel() { failure = .cancelled }
        if let failure {
            if let processGroup { kill(-processGroup, SIGTERM) }
            else if process.isRunning { process.terminate() }
            let didExit = exited.wait(timeout: .now() + .milliseconds(250)) == .success
            if let processGroup {
                // 父进程可能先退出，忽略 SIGTERM 的后代仍留在原进程组中。
                kill(-processGroup, SIGKILL)
            } else if !didExit, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw failure
        }
        process.waitUntilExit()
        guard !request.shouldCancel() else { throw TokscaleError.cancelled }
        guard Self.size(stdoutURL) <= request.maximumOutputBytes,
              Self.size(stderrURL) <= request.maximumErrorBytes else { throw TokscaleError.outputTooLarge }
        guard process.terminationStatus == 0 else { throw TokscaleError.processFailed(process.terminationStatus) }
        return try Data(contentsOf: stdoutURL)
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}
