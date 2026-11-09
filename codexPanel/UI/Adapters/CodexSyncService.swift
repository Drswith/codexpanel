import AppKit
import CodexPanelCore
import CryptoKit
import Foundation
import SQLite3

protocol CodexSynchronizing {
    func synchronize(config: CodexPanelConfig) throws
}

typealias CodexSyncError = CodexConfigurationSyncError

/// macOS App adapter：只负责把 UI 模型、运行 profile 与路径映射到 Core 契约。
struct CodexSyncService: CodexSynchronizing {
    private static let syncLock = NSLock()
    private let desktopIsRunning: () -> Bool
    private let readData: (URL) -> Data?
    private let synchronizer: CodexConfigurationSynchronizer
    private let networkConfiguration: CodexPanelRuntimeNetworkConfiguration

    init(
        networkConfiguration: CodexPanelRuntimeNetworkConfiguration = CodexPanelRuntimeProfile.current.network,
        ensureDirectories: @escaping () throws -> Void = { try CodexPaths.ensureDirectories() },
        backupFileIfPresent: @escaping (URL, URL) throws -> Void = { source, destination in
            try CodexPaths.backupFileIfPresent(from: source, to: destination)
        },
        writeSecureFile: @escaping (Data, URL) throws -> Void = { data, url in
            try CodexPaths.writeSecureFile(data, to: url)
        },
        readString: @escaping (URL) -> String? = { url in
            try? String(contentsOf: url, encoding: .utf8)
        },
        readData: @escaping (URL) -> Data? = { url in
            try? Data(contentsOf: url)
        },
        fileExists: @escaping (URL) -> Bool = { url in
            FileManager.default.fileExists(atPath: url.path)
        },
        removeFileIfPresent: @escaping (URL) throws -> Void = { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        },
        desktopIsRunning: @escaping () -> Bool = {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").contains { !$0.isTerminated }
        }
    ) {
        let paths = CodexConfigurationPaths(
            authURL: CodexPaths.authURL,
            configTOMLURL: CodexPaths.configTomlURL,
            authBackupURL: CodexPaths.authBackupURL,
            configBackupURL: CodexPaths.configBackupURL
        )
        let fileSystem = CodexConfigurationFileSystem(
            prepare: ensureDirectories,
            readData: readData,
            readString: readString,
            backupFileIfPresent: backupFileIfPresent,
            writeSecureFile: writeSecureFile,
            fileExists: fileExists,
            removeFileIfPresent: removeFileIfPresent
        )
        self.synchronizer = CodexConfigurationSynchronizer(
            paths: paths,
            fileSystem: fileSystem
        )
        self.networkConfiguration = networkConfiguration
        self.desktopIsRunning = desktopIsRunning
        self.readData = readData
    }

    func synchronize(config: CodexPanelConfig) throws {
        let request = try self.makeRequest(config: config)
        Self.syncLock.lock()
        defer { Self.syncLock.unlock() }
        try self.preserveDesktopSidebar(for: request) {
            try self.synchronizer.synchronize(request)
        }
    }

    private func preserveDesktopSidebar(
        for request: CodexConfigurationSyncRequest,
        synchronize: () throws -> Void
    ) throws {
        let home = CodexPaths.codexRoot
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard request.provider.kind == .openAIOAuth,
              let auth = self.readData(CodexPaths.authURL),
              let object = try? JSONSerialization.jsonObject(with: auth) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any]
        else { return try synchronize() }

        let oldOwner = Self.sidebarOwner(
            accountID: tokens["account_id"] as? String,
            accessToken: tokens["access_token"] as? String
        )
        let newOwner = Self.sidebarOwner(
            accountID: request.credentials.accountID,
            accessToken: request.credentials.accessToken
        )
        if let oldOwner, oldOwner == newOwner { return try synchronize() }

        let original: Data
        do {
            original = try Data(contentsOf: file)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return try synchronize()
        }
        guard let state = try JSONSerialization.jsonObject(with: original) as? [String: Any]
        else { throw SidebarSwitchError.invalidIdentity }
        guard state[DesktopSidebarState.scopeKey] != nil else { return try synchronize() }
        guard let oldOwner, let newOwner,
              try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false
        else { throw SidebarSwitchError.invalidIdentity }
        let updated: Data?
        do {
            updated = try DesktopSidebarState.merge(
                state, source: oldOwner, target: newOwner,
                codexHome: home
            ) { try Self.sidebarProjectIndex(database: CodexPaths.stateSQLiteURL) }
        } catch is DesktopSidebarState.MergeError {
            throw SidebarSwitchError.invalidIdentity
        }
        guard let merged = updated else { return try synchronize() }

        guard !self.desktopIsRunning() else { throw SidebarSwitchError.desktopRunning }
        let backup = home.appendingPathComponent(".codex-global-state.json.bak-codexpanel-\(UUID().uuidString)")
        try CodexPaths.writeSecureFile(original, to: backup)
        guard !self.desktopIsRunning(), try Data(contentsOf: file) == original,
              self.readData(CodexPaths.authURL) == auth
        else { throw SidebarSwitchError.stateChanged }
        try merged.write(to: file, options: .atomic)
        do {
            try synchronize()
        } catch {
            guard !self.desktopIsRunning(), try Data(contentsOf: file) == merged
            else { throw SidebarSwitchError.stateChanged }
            try original.write(to: file, options: .atomic)
            throw error
        }
    }

    static func sidebarProjectIndex(database: URL) throws -> DesktopSidebarState.ProjectIndex {
        var db: OpaquePointer?
        defer { if let db { sqlite3_close(db) } }
        guard sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else { throw SidebarSwitchError.invalidIdentity }

        func scan(_ query: String, row: (OpaquePointer) -> Void) throws {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK, let statement
            else { throw SidebarSwitchError.invalidIdentity }
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_DONE: return
                case SQLITE_ROW: row(statement)
                default: throw SidebarSwitchError.invalidIdentity
                }
            }
        }

        var roots: [String: [String]] = [:]
        var threads: [String: DesktopSidebarState.ProjectIndex.Thread] = [:]
        try scan("SELECT project_id, path FROM project_roots") { row in
            guard let id = sqlite3_column_text(row, 0), let path = sqlite3_column_text(row, 1) else { return }
            roots[String(cString: id), default: []].append(String(cString: path))
        }
        try scan("SELECT id, cwd, project_id FROM threads") { row in
            guard let id = sqlite3_column_text(row, 0), let cwd = sqlite3_column_text(row, 1) else { return }
            threads[String(cString: id)] = .init(
                cwd: String(cString: cwd),
                projectID: sqlite3_column_text(row, 2).map { String(cString: $0) }
            )
        }
        return .init(roots: roots, threads: threads)
    }

    static func sidebarOwner(accountID: String?, accessToken: String?) -> String? {
        guard let accountID, !accountID.isEmpty, let accessToken,
              let userID = AccountBuilder.chatGPTUserID(fromAccessToken: accessToken),
              let encoded = try? JSONSerialization.data(withJSONObject: [userID, accountID], options: .withoutEscapingSlashes)
        else { return nil }
        return SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }

    enum SidebarSwitchError: LocalizedError {
        case invalidIdentity
        case desktopRunning
        case stateChanged

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: L.sidebarSwitchIdentityError
            case .desktopRunning: L.sidebarSwitchQuitDesktop
            case .stateChanged: L.sidebarSwitchStateChanged
            }
        }
    }

    private func makeRequest(config: CodexPanelConfig) throws -> CodexConfigurationSyncRequest {
        guard let provider = config.activeProvider() else {
            throw CodexSyncError.missingActiveProvider
        }
        guard let account = config.activeAccount() else {
            throw CodexSyncError.missingActiveAccount
        }

        let providerKind: CodexProviderKind
        switch provider.kind {
        case .openAIOAuth:
            providerKind = .openAIOAuth
        case .openAICompatible:
            providerKind = .openAICompatible
        case .openRouter:
            providerKind = .openRouter
        }

        return CodexConfigurationSyncRequest(
            provider: CodexProviderConfiguration(
                kind: providerKind,
                baseURL: provider.baseURL,
                wireAPI: provider.wireAPI == .chat ? .chat : .responses
            ),
            credentials: CodexAccountCredentials(
                accessToken: account.accessToken,
                refreshToken: account.refreshToken,
                idToken: account.idToken,
                accountID: account.openAIAccountId,
                apiKey: account.apiKey,
                oauthClientID: account.oauthClientID,
                lastRefreshAt: account.tokenLastRefreshAt ?? account.lastRefresh
            ),
            accountUsageMode: config.openAI.accountUsageMode == .aggregateGateway
                ? .aggregateGateway
                : .direct,
            network: CodexNetworkConfiguration(
                openAIAccountGatewayBaseURL: self.networkConfiguration.openAIAccountGatewayBaseURLString,
                openRouterGatewayBaseURL: self.networkConfiguration.openRouterGatewayBaseURLString,
                chatCompletionsGatewayBaseURL: self.networkConfiguration.chatCompletionsGatewayBaseURLString,
                openRouterGatewayAPIKey: OpenRouterGatewayConfiguration.apiKey
            )
        )
    }
}
