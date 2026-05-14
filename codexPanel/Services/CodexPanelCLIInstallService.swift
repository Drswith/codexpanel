import Foundation

enum CodexPanelCLIInstallError: LocalizedError {
    case helperMissing(path: String)
    case createInstallDirectoryFailed(path: String, message: String)
    case removeExistingInstallFailed(path: String, message: String)
    case createSymlinkFailed(path: String, message: String)

    var errorDescription: String? {
        switch self {
        case .helperMissing(let path):
            return L.codexPanelCLIInstallHelperMissing(path)
        case .createInstallDirectoryFailed(let path, let message):
            return L.codexPanelCLIInstallCreateDirectoryFailed(path, message)
        case .removeExistingInstallFailed(let path, let message):
            return L.codexPanelCLIInstallRemoveExistingFailed(path, message)
        case .createSymlinkFailed(let path, let message):
            return L.codexPanelCLIInstallCreateSymlinkFailed(path, message)
        }
    }
}

struct CodexPanelCLIInstallResult: Equatable {
    var helperPath: String
    var installPath: String
}

enum CodexPanelCLIInstallStatus: Equatable {
    case helperMissing(helperPath: String, installPath: String)
    case notInstalled(helperPath: String, installPath: String)
    case installed(helperPath: String, installPath: String, linkedTarget: String?)
}

struct CodexPanelCLIInstallService {
    private let fileManager: FileManager
    private let installURL: URL
    private let helperURL: URL

    init(
        fileManager: FileManager = .default,
        installURL: URL? = nil,
        helperURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.installURL = installURL ?? CodexPaths.realHome
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codexpanel", isDirectory: false)
        self.helperURL = helperURL ?? Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("codexpanel", isDirectory: false)
    }

    func status() -> CodexPanelCLIInstallStatus {
        let helperPath = self.helperURL.path
        let installPath = self.installURL.path
        guard self.fileManager.fileExists(atPath: helperPath) else {
            return .helperMissing(helperPath: helperPath, installPath: installPath)
        }
        guard self.fileManager.fileExists(atPath: installPath) else {
            return .notInstalled(helperPath: helperPath, installPath: installPath)
        }

        let linkedTarget = try? self.fileManager.destinationOfSymbolicLink(atPath: installPath)
        return .installed(
            helperPath: helperPath,
            installPath: installPath,
            linkedTarget: linkedTarget
        )
    }

    func installSymlink() throws -> CodexPanelCLIInstallResult {
        let helperPath = self.helperURL.path
        guard self.fileManager.fileExists(atPath: helperPath) else {
            throw CodexPanelCLIInstallError.helperMissing(path: helperPath)
        }

        let installPath = self.installURL.path
        let installDirectoryPath = self.installURL.deletingLastPathComponent().path

        do {
            try self.fileManager.createDirectory(
                at: self.installURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw CodexPanelCLIInstallError.createInstallDirectoryFailed(
                path: installDirectoryPath,
                message: error.localizedDescription
            )
        }

        if self.fileManager.fileExists(atPath: installPath) {
            do {
                try self.fileManager.removeItem(atPath: installPath)
            } catch {
                throw CodexPanelCLIInstallError.removeExistingInstallFailed(
                    path: installPath,
                    message: error.localizedDescription
                )
            }
        }

        do {
            try self.fileManager.createSymbolicLink(atPath: installPath, withDestinationPath: helperPath)
        } catch {
            throw CodexPanelCLIInstallError.createSymlinkFailed(
                path: installPath,
                message: error.localizedDescription
            )
        }

        return CodexPanelCLIInstallResult(
            helperPath: helperPath,
            installPath: installPath
        )
    }
}
