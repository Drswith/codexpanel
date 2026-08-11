import Foundation

public struct CodexConfigurationPaths: Equatable, Sendable {
    public var authURL: URL
    public var configTOMLURL: URL
    public var authBackupURL: URL
    public var configBackupURL: URL

    public init(
        authURL: URL,
        configTOMLURL: URL,
        authBackupURL: URL,
        configBackupURL: URL
    ) {
        self.authURL = authURL
        self.configTOMLURL = configTOMLURL
        self.authBackupURL = authBackupURL
        self.configBackupURL = configBackupURL
    }
}

/// 文件系统是 Core 的 port；App、测试以及未来 sidecar 均可提供自己的 adapter。
public struct CodexConfigurationFileSystem {
    public var prepare: () throws -> Void
    public var readData: (URL) -> Data?
    public var readString: (URL) -> String?
    public var backupFileIfPresent: (URL, URL) throws -> Void
    public var writeSecureFile: (Data, URL) throws -> Void
    public var fileExists: (URL) -> Bool
    public var removeFileIfPresent: (URL) throws -> Void

    public init(
        prepare: @escaping () throws -> Void,
        readData: @escaping (URL) -> Data?,
        readString: @escaping (URL) -> String?,
        backupFileIfPresent: @escaping (URL, URL) throws -> Void,
        writeSecureFile: @escaping (Data, URL) throws -> Void,
        fileExists: @escaping (URL) -> Bool,
        removeFileIfPresent: @escaping (URL) throws -> Void
    ) {
        self.prepare = prepare
        self.readData = readData
        self.readString = readString
        self.backupFileIfPresent = backupFileIfPresent
        self.writeSecureFile = writeSecureFile
        self.fileExists = fileExists
        self.removeFileIfPresent = removeFileIfPresent
    }

    public static var live: CodexConfigurationFileSystem {
        let fileManager = FileManager.default
        return CodexConfigurationFileSystem(
            prepare: {},
            readData: { try? Data(contentsOf: $0) },
            readString: { try? String(contentsOf: $0, encoding: .utf8) },
            backupFileIfPresent: { source, destination in
                guard fileManager.fileExists(atPath: source.path) else { return }
                try Self.writeSecureFile(Data(contentsOf: source), to: destination, fileManager: fileManager)
            },
            writeSecureFile: { data, url in
                try Self.writeSecureFile(data, to: url, fileManager: fileManager)
            },
            fileExists: { fileManager.fileExists(atPath: $0.path) },
            removeFileIfPresent: { url in
                guard fileManager.fileExists(atPath: url.path) else { return }
                try fileManager.removeItem(at: url)
            }
        )
    }

    private static func writeSecureFile(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try data.write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: temporaryURL, to: url)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}

/// Core 用例入口：负责渲染、备份、写入以及失败回滚，宿主只负责模型映射与平台接线。
public struct CodexConfigurationSynchronizer {
    private let paths: CodexConfigurationPaths
    private let fileSystem: CodexConfigurationFileSystem
    private let renderer: CodexConfigurationRenderer
    private let now: () -> Date

    public init(
        paths: CodexConfigurationPaths,
        fileSystem: CodexConfigurationFileSystem = .live,
        renderer: CodexConfigurationRenderer = CodexConfigurationRenderer(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.paths = paths
        self.fileSystem = fileSystem
        self.renderer = renderer
        self.now = now
    }

    public func synchronize(_ request: CodexConfigurationSyncRequest) throws {
        let previousAuthData = self.fileSystem.readData(self.paths.authURL)
        let previousTOMLData = self.fileSystem.readData(self.paths.configTOMLURL)
        let existingTOML = self.fileSystem.readString(self.paths.configTOMLURL) ?? ""

        let rendered = try self.renderer.render(
            request: request,
            existingConfigTOML: existingTOML,
            now: self.now()
        )

        try self.fileSystem.prepare()
        try self.fileSystem.backupFileIfPresent(
            self.paths.configTOMLURL,
            self.paths.configBackupURL
        )
        try self.fileSystem.backupFileIfPresent(
            self.paths.authURL,
            self.paths.authBackupURL
        )

        do {
            try self.fileSystem.writeSecureFile(rendered.authJSON, self.paths.authURL)
            try self.fileSystem.writeSecureFile(rendered.configTOML, self.paths.configTOMLURL)
        } catch {
            try? self.restore(previousAuthData, at: self.paths.authURL)
            try? self.restore(previousTOMLData, at: self.paths.configTOMLURL)
            throw error
        }
    }

    private func restore(_ snapshot: Data?, at url: URL) throws {
        if let snapshot {
            try self.fileSystem.writeSecureFile(snapshot, url)
        } else if self.fileSystem.fileExists(url) {
            try self.fileSystem.removeFileIfPresent(url)
        }
    }
}
