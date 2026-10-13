import AppKit
import CryptoKit
import Foundation

nonisolated struct CodexModelCatalogRequest: Sendable {
    let accessToken: String
    let accountID: String
    let planType: String?
    let preferredAppPath: String?
}

@MainActor
protocol CodexModelCatalogFetching {
    func fetchCatalog(_ request: CodexModelCatalogRequest) async throws -> CodexModelCatalog
}

nonisolated enum CodexModelCatalogError: Error, LocalizedError, Equatable {
    case executableMissing, timedOut, invalidResponse, authenticationRequired, emptyCatalog, cancelled
    var errorDescription: String? {
        switch self {
        case .executableMissing: return "未找到 Codex 可执行文件，请检查 Codex 应用路径。"
        case .timedOut: return "模型目录刷新超时，已保留原有目录。"
        case .authenticationRequired: return "模型目录需要有效的账号登录状态，已保留原有目录。"
        case .emptyCatalog, .invalidResponse: return "Codex 未返回有效模型目录，已保留原有目录。"
        case .cancelled: return "模型目录刷新已取消。"
        }
    }
}

struct CodexModelCatalogService: CodexModelCatalogFetching {
    let timeout: TimeInterval
    let executableResolver: @MainActor @Sendable (String?) -> URL?

    nonisolated init(
        timeout: TimeInterval = 25,
        executableResolver: @escaping @MainActor @Sendable (String?) -> URL? = { Self.resolveExecutable($0) }
    ) {
        self.timeout = timeout
        self.executableResolver = executableResolver
    }

    func fetchCatalog(_ request: CodexModelCatalogRequest) async throws -> CodexModelCatalog {
        guard let executable = self.executableResolver(request.preferredAppPath) else {
            throw CodexModelCatalogError.executableMissing
        }
        let session = CodexModelListSession(executable: executable, timeout: self.timeout)
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try session.fetch(request) }.value
        } onCancel: {
            session.cancel()
        }
    }

    static func resolveExecutable(_ preferredAppPath: String?) -> URL? {
        var apps: [URL] = []
        if let preferredAppPath, (preferredAppPath as NSString).isAbsolutePath {
            apps.append(URL(fileURLWithPath: preferredAppPath))
        }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            apps.append(app)
        }
        apps += ["/Applications/ChatGPT.app", "/Applications/Codex.app"].map { URL(fileURLWithPath: $0) }
        for app in apps {
            if let executable = Self.bundledExecutable(in: app) { return executable }
        }
        // 菜单栏进程 PATH 通常不包含用户 CLI 目录；显式检查常用安装位置。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [home.appendingPathComponent(".local/bin/codex"), home.appendingPathComponent(".bun/bin/codex")]
            + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func bundledExecutable(in app: URL) -> URL? {
        guard ["ChatGPT.app", "Codex.app"].contains(app.lastPathComponent) else { return nil }
        // 兼容合并后的 ChatGPT 桌面包与此前独立 Codex.app 的布局。
        let paths = ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                     "Contents/Resources/codex-cli/bin/codex", "Contents/Resources/codex"]
        return paths.map { app.appendingPathComponent($0) }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

}

/// 只发送 initialize、外部令牌登录和 model/list，不创建会话或运行模型。
/// 凭据仅经 stdin 传入；不继承原有 CODEX_HOME，不复制 auth/config，不记录服务端原始错误。
nonisolated final class CodexModelListSession: @unchecked Sendable {
    private let executable: URL
    private let timeout: TimeInterval
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var stopped = false
    private var timeoutReached = false
    private var buffer = Data()
    private var nextID = 0

    init(executable: URL, timeout: TimeInterval) {
        self.executable = executable
        self.timeout = timeout
    }

    func cancel() { self.stop(timedOut: false) }

    private func stop(timedOut: Bool) {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.stopped else { return }
        self.stopped = true
        self.timeoutReached = timedOut
        if self.process.isRunning { kill(self.process.processIdentifier, SIGKILL) }
    }

    func fetch(_ credentials: CodexModelCatalogRequest) throws -> CodexModelCatalog {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codexpanel-model-list-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        // 禁止父进程的 API Key / base URL 将 OAuth 查询导向其他供应商。
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_API_KEY", "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH"] { environment.removeValue(forKey: key) }
        self.process.executableURL = self.executable
        self.process.arguments = ["app-server"]
        self.process.environment = environment
        self.process.currentDirectoryURL = home
        self.process.standardInput = self.input
        self.process.standardOutput = self.output
        self.process.standardError = FileHandle.nullDevice
        self.lock.lock()
        if self.stopped { self.lock.unlock(); throw CodexModelCatalogError.cancelled }
        do { try self.process.run() } catch { self.lock.unlock(); throw CodexModelCatalogError.executableMissing }
        self.lock.unlock()
        try? self.output.fileHandleForWriting.close()
        try? self.input.fileHandleForReading.close()
        _ = fcntl(self.input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + self.timeout)
        timer.setEventHandler { [weak self] in self?.stop(timedOut: true) }
        timer.resume()
        defer {
            timer.cancel()
            self.stop(timedOut: false)
            try? self.input.fileHandleForWriting.close()
            self.process.waitUntilExit()
            try? self.output.fileHandleForReading.close()
        }
        _ = try self.request("initialize", params: [
            "clientInfo": ["name": "codexpanel", "title": "Codex Panel", "version": "1.0"],
            "capabilities": ["experimentalApi": true],
        ])
        try self.send(["method": "initialized", "params": [:]])
        var login: [String: Any] = ["type": "chatgptAuthTokens", "accessToken": credentials.accessToken, "chatgptAccountId": credentials.accountID]
        if let plan = credentials.planType { login["chatgptPlanType"] = plan }
        _ = try self.request("account/login/start", params: login)
        var models: [CodexModelCatalog.Model] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": true]
            if let cursor { params["cursor"] = cursor }
            let response = try self.request("model/list", params: params)
            let page = try Self.parsePage(response)
            models.append(contentsOf: page.models)
            cursor = page.nextCursor
            if let cursor, !seenCursors.insert(cursor).inserted { throw CodexModelCatalogError.invalidResponse }
            if models.count > 10_000 { throw CodexModelCatalogError.invalidResponse }
        } while cursor != nil
        guard !models.isEmpty else { throw CodexModelCatalogError.emptyCatalog }
        var seenModels = Set<String>()
        let catalog = CodexModelCatalog(models: models.filter { seenModels.insert($0.slug).inserted }, fetchedAt: Date())
        // model/list 的能力以 RPC 为准，服务档位来自同一账号刚生成的缓存。
        let cacheURL = home.appendingPathComponent("models_cache.json")
        let cache = (try? Data(contentsOf: cacheURL)).flatMap { try? CodexModelCatalog.parse($0) }
        return catalog.mergingServiceTiers(from: cache)
    }

    static func parsePage(_ response: [String: Any]) throws -> (models: [CodexModelCatalog.Model], nextCursor: String?) {
        guard let entries = response["data"] as? [[String: Any]] else { throw CodexModelCatalogError.invalidResponse }
        let models = entries.compactMap { entry -> CodexModelCatalog.Model? in
            guard let id = (entry["model"] as? String ?? entry["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
            let efforts = (entry["supportedReasoningEfforts"] as? [[String: Any]])?.compactMap { $0["reasoningEffort"] as? String }
            return CodexModelCatalog.Model(slug: id, displayName: entry["displayName"] as? String,
                hidden: entry["hidden"] as? Bool ?? false,
                reasoningEfforts: efforts.map(CodexModelCatalog.uniqueStrings),
                defaultReasoningEffort: entry["defaultReasoningEffort"] as? String,
                hasServiceTierMetadata: false)
        }
        return (models, response["nextCursor"] as? String)
    }

    private func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message) + Data([10])
        try self.input.fileHandleForWriting.write(contentsOf: data)
    }

    private func request(_ method: String, params: [String: Any]) throws -> [String: Any] {
        self.nextID += 1
        let id = self.nextID
        try self.send(["id": id, "method": method, "params": params])
        while true {
            if let newline = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: newline)
                self.buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw CodexModelCatalogError.invalidResponse }
                if message["method"] as? String == "account/chatgptAuthTokens/refresh" {
                    throw CodexModelCatalogError.authenticationRequired
                }
                guard message["id"] as? Int == id, message["method"] == nil else { continue }
                if message["error"] != nil { throw CodexModelCatalogError.invalidResponse }
                guard let result = message["result"] as? [String: Any] else { throw CodexModelCatalogError.invalidResponse }
                return result
            }
            let chunk = self.output.fileHandleForReading.availableData
            guard !chunk.isEmpty else {
                self.lock.lock()
                let timedOut = self.timeoutReached
                let cancelled = self.stopped
                self.lock.unlock()
                throw timedOut ? CodexModelCatalogError.timedOut : (cancelled ? CodexModelCatalogError.cancelled : .invalidResponse)
            }
            self.buffer.append(chunk)
            if self.buffer.count > 4 * 1024 * 1024 { throw CodexModelCatalogError.invalidResponse }
        }
    }
}

/// 账号目录写在 Panel 自己的数据目录，不覆盖 Codex 管理的缓存。
struct CodexModelCatalogSnapshotStore {
    var rootURL: URL = CodexPaths.codexBarRoot.appendingPathComponent("model-catalogs", isDirectory: true)
    func url(for accountID: String) -> URL {
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return self.rootURL.appendingPathComponent(key + ".json")
    }
    func load(accountID: String) -> CodexModelCatalog? {
        guard let data = try? Data(contentsOf: self.url(for: accountID)) else { return nil }
        return try? JSONDecoder().decode(CodexModelCatalog.self, from: data)
    }
    func save(_ catalog: CodexModelCatalog, accountID: String) throws {
        try CodexPaths.writeSecureFile(JSONEncoder().encode(catalog), to: self.url(for: accountID))
    }
}
