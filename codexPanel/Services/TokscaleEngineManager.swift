import CryptoKit
import Darwin
import Foundation

nonisolated enum TokscaleEngineSource: String, Codable, CaseIterable, Sendable {
    case installed
    case managed
}

nonisolated struct TokscaleEngineDescriptor: Identifiable, Equatable, Sendable {
    let source: TokscaleEngineSource
    let executableURL: URL
    let version: String

    var id: String { self.source.rawValue + ":" + self.executableURL.path }
    var isCompatible: Bool { TokscaleVersion.isCompatible(self.version) }
}

nonisolated enum TokscaleVersion {
    static func components(_ value: String) -> [Int]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { return nil }
        let numbers = pieces.compactMap { piece -> Int? in
            guard !piece.isEmpty, piece.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(piece)
        }
        return numbers.count == 3 ? numbers : nil
    }

    static func isCompatible(_ value: String) -> Bool {
        guard let numbers = self.components(value) else { return false }
        return numbers[0] == 4 && numbers[1] >= 20
    }

    static func parseOutput(_ output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0].lowercased() == "tokscale", self.components(String(words[1])) != nil else { return nil }
        return String(words[1])
    }
}

nonisolated protocol TokscaleEngineManaging: Sendable {
    func discover() throws -> [TokscaleEngineDescriptor]
    func installManaged() throws -> TokscaleEngineDescriptor
}

nonisolated enum TokscaleEngineError: LocalizedError, Equatable {
    case manifestMissing
    case invalidManifest
    case downloadFailed
    case downloadTooLarge
    case checksumMismatch
    case invalidArchive
    case invalidVersion
    case installationFailed

    var errorDescription: String? {
        switch self {
        case .manifestMissing: return "缺少 tokscale 下载清单，请重新安装 Codex Panel。"
        case .invalidManifest: return "tokscale 下载清单无效。"
        case .downloadFailed: return "tokscale 下载失败，请检查网络后重试。"
        case .downloadTooLarge: return "tokscale 下载文件超过大小限制。"
        case .checksumMismatch: return "tokscale 文件校验失败，未安装下载内容。"
        case .invalidArchive: return "tokscale 安装包内容无效。"
        case .invalidVersion: return "无法确认 tokscale 版本。"
        case .installationFailed: return "无法安装 Codex Panel 管理的 tokscale 副本。"
        }
    }
}

nonisolated protocol TokscalePackageDownloading: Sendable {
    func download(from url: URL, to destination: URL) throws
}

/// 发现和安装都由调用方放到后台；初始化不探测路径、不启动进程。
nonisolated final class TokscaleEngineManager: TokscaleEngineManaging, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.codexpanel.tokscale.engines", qos: .utility)
    private let managedRoot: () -> URL
    private let userHome: () -> URL
    private let inheritedEnvironment: () -> [String: String]
    private let searchPathOverride: (() -> String)?
    private let manifestData: () throws -> Data
    private let downloader: any TokscalePackageDownloading
    private let runner: any TokscaleProcessRunning
    private let architecture: String

    init(
        managedRootURL: URL? = nil,
        userHomeURL: URL? = nil,
        inheritedEnvironment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        searchPathProvider: (() -> String)? = nil,
        manifestDataProvider: @escaping () throws -> Data = {
            guard let url = Bundle.main.url(forResource: "tokscale-manifest", withExtension: "json") else { throw TokscaleEngineError.manifestMissing }
            return try Data(contentsOf: url)
        },
        downloader: any TokscalePackageDownloading = TokscalePackageDownloader(),
        processRunner: any TokscaleProcessRunning = TokscaleProcessRunner(),
        architecture: String = TokscaleEngineManager.currentArchitecture
    ) {
        self.managedRoot = { managedRootURL ?? CodexPaths.codexBarRoot.appendingPathComponent("engines/tokscale", isDirectory: true) }
        self.userHome = { userHomeURL ?? FileManager.default.homeDirectoryForCurrentUser }
        self.inheritedEnvironment = inheritedEnvironment
        self.searchPathOverride = searchPathProvider
        self.manifestData = manifestDataProvider
        self.downloader = downloader
        self.runner = processRunner
        self.architecture = architecture
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    static func executionPath(inherited: [String: String], userHome: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        var directories = (inherited["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        directories += [".local/bin", ".bun/bin", ".cargo/bin", ".npm-global/bin", ".volta/bin", ".local/share/mise/shims"].map { userHome.appendingPathComponent($0).path }
        let nvm = userHome.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(at: nvm, includingPropertiesForKeys: nil) {
            directories += versions.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.map { $0.appendingPathComponent("bin").path }
        }
        var seen: Set<String> = []
        return directories.filter { seen.insert($0).inserted }.joined(separator: ":")
    }

    func discover() throws -> [TokscaleEngineDescriptor] {
        self.queue.sync {
            let root = self.managedRoot()
            let path = self.searchPathOverride?() ?? Self.executionPath(inherited: self.inheritedEnvironment(), userHome: self.userHome())
            let resolvedManaged = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            let managedPath = root.standardizedFileURL.path + "/"
            var seen: Set<String> = []
            var engines: [TokscaleEngineDescriptor] = []
            for directory in path.split(separator: ":") {
                let executable = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("tokscale")
                let resolved = executable.resolvingSymlinksInPath().standardizedFileURL.path
                guard !resolved.hasPrefix(resolvedManaged), !executable.standardizedFileURL.path.hasPrefix(managedPath), seen.insert(resolved).inserted,
                      FileManager.default.isExecutableFile(atPath: executable.path),
                      let version = try? self.probe(executable, path: path) else { continue }
                engines.append(TokscaleEngineDescriptor(source: .installed, executableURL: executable, version: version))
            }
            if let manifest = try? self.readManifest() {
                let executable = self.installationURL(root: root, version: manifest.version)
                if FileManager.default.isExecutableFile(atPath: executable.path),
                   let version = try? self.probe(executable, path: "/usr/bin:/bin:/usr/sbin:/sbin") {
                    engines.append(TokscaleEngineDescriptor(source: .managed, executableURL: executable, version: version))
                }
            }
            return engines
        }
    }

    func installManaged() throws -> TokscaleEngineDescriptor {
        try self.queue.sync {
            let manifest = try self.readManifest()
            guard let spec = manifest.platforms[self.architecture] else { throw TokscaleEngineError.invalidManifest }
            let root = self.managedRoot()
            let destination = self.installationURL(root: root, version: manifest.version)
            let parent = destination.deletingLastPathComponent()
            // 管理目录和版本目录不能通过符号链接把安装重定向到系统 PATH。
            for directory in [root.deletingLastPathComponent().deletingLastPathComponent(), root.deletingLastPathComponent(), root, root.appendingPathComponent(manifest.version), parent] {
                if (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw TokscaleEngineError.installationFailed }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            let staging = parent.appendingPathComponent(".install-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            let archive = staging.appendingPathComponent("package.tgz")
            try self.downloader.download(from: spec.url, to: archive)
            let package = try Data(contentsOf: archive, options: .mappedIfSafe)
            guard package.count <= 64 * 1_024 * 1_024 else { throw TokscaleEngineError.downloadTooLarge }
            guard "sha512-" + Data(SHA512.hash(data: package)).base64EncodedString() == spec.integrity else { throw TokscaleEngineError.checksumMismatch }
            let environment = self.probeEnvironment(root: staging, path: "/usr/bin:/bin:/usr/sbin:/sbin")
            func tar(_ flag: String, limit: Int) throws -> Data {
                try self.runner.run(TokscaleProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/tar"), arguments: [flag, archive.path, "--", "package/bin/tokscale"], environment: environment, workingDirectoryURL: staging, timeout: 30, maximumOutputBytes: limit))
            }
            let names = String(decoding: try tar("-tzf", limit: 4_096), as: UTF8.self).split(whereSeparator: \.isNewline)
            let details = String(decoding: try tar("-tvzf", limit: 4_096), as: UTF8.self).split(whereSeparator: \.isNewline)
            guard names.count == 1, names[0] == "package/bin/tokscale", details.count == 1, details[0].first == "-" else { throw TokscaleEngineError.invalidArchive }
            // 只把指定普通成员写到 stdout；不在磁盘展开 tar 路径或链接。
            let binary = try tar("-xOzf", limit: 64 * 1_024 * 1_024)
            guard !binary.isEmpty, SHA256.hash(data: binary).map({ String(format: "%02x", $0) }).joined() == spec.binarySHA256 else { throw TokscaleEngineError.checksumMismatch }
            let candidate = staging.appendingPathComponent("tokscale")
            try binary.write(to: candidate, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: candidate.path)
            guard try self.probe(candidate, path: "/usr/bin:/bin:/usr/sbin:/sbin") == manifest.version else { throw TokscaleEngineError.invalidVersion }
            guard rename(candidate.path, destination.path) == 0 else { throw TokscaleEngineError.installationFailed }
            return TokscaleEngineDescriptor(source: .managed, executableURL: destination, version: manifest.version)
        }
    }

    private func installationURL(root: URL, version: String) -> URL {
        root.appendingPathComponent(version).appendingPathComponent(self.architecture).appendingPathComponent("tokscale")
    }

    private func probe(_ executable: URL, path: String) throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codexpanel-tokscale-probe-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try self.runner.run(TokscaleProcessRequest(executableURL: executable, arguments: ["--version"], environment: self.probeEnvironment(root: root, path: path), workingDirectoryURL: root, timeout: 5, maximumOutputBytes: 64 * 1_024, maximumErrorBytes: 64 * 1_024))
        guard let version = TokscaleVersion.parseOutput(data) else { throw TokscaleEngineError.invalidVersion }
        return version
    }

    private func probeEnvironment(root: URL, path: String) -> [String: String] {
        var environment = TokscaleCostSummaryService.environment(codexRoot: root.appendingPathComponent("codex"), stateRoot: root, timeZone: TimeZone(secondsFromGMT: 0)!, inherited: [:], cacheOnly: true)
        environment["PATH"] = path
        return environment
    }

    private struct Manifest: Decodable {
        struct Platform: Decodable {
            let url: URL
            let integrity: String
            let binarySHA256: String
        }
        let version: String
        let platforms: [String: Platform]
    }

    private func readManifest() throws -> Manifest {
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: self.manifestData()) }
        catch let error as TokscaleEngineError { throw error }
        catch { throw TokscaleEngineError.invalidManifest }
        guard manifest.version == "4.20.0", let spec = manifest.platforms[self.architecture],
              spec.url.scheme == "https", spec.url.host == "registry.npmjs.org", spec.url.port == nil,
              spec.url.user == nil, spec.url.password == nil,
              spec.integrity.hasPrefix("sha512-"), Data(base64Encoded: String(spec.integrity.dropFirst(7)))?.count == 64,
              spec.binarySHA256.count == 64, spec.binarySHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw TokscaleEngineError.invalidManifest }
        return manifest
    }
}

nonisolated struct TokscalePackageDownloader: TokscalePackageDownloading {
    func download(from url: URL, to destination: URL) throws {
        let delegate = TokscaleDownloadDelegate(destination: destination)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: url).resume()
        guard delegate.finished.wait(timeout: .now() + 305) == .success else {
            delegate.cancel()
            throw TokscaleEngineError.downloadFailed
        }
        try delegate.result.get()
    }
}

nonisolated private final class TokscaleDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let destination: URL
    private let lock = NSLock()
    private var rejected = false
    private var storedResult: Result<Void, Error> = .failure(TokscaleEngineError.downloadFailed)
    var result: Result<Void, Error> { self.lock.withLock { self.storedResult } }
    init(destination: URL) { self.destination = destination }
    func cancel() {
        self.lock.withLock { self.rejected = true; self.storedResult = .failure(TokscaleEngineError.downloadFailed) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "registry.npmjs.org" ? request : nil)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > 64 * 1_024 * 1_024 {
            self.lock.withLock { self.rejected = true; self.storedResult = .failure(TokscaleEngineError.downloadTooLarge) }
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 64 * 1_024 * 1_024 else { return }
        self.lock.withLock {
            guard !self.rejected else { return }
            do { try FileManager.default.moveItem(at: location, to: self.destination); self.storedResult = .success(()) }
            catch { self.storedResult = .failure(TokscaleEngineError.downloadFailed) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.finished.signal()
    }
}
