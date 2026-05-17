import AppKit
import Foundation

final class CodexPanelAppLocator {
    private let identity: CLIRuntimeIdentity
    private let executablePathProvider: () -> String
    private let fileManager: FileManager

    init(
        identity: CLIRuntimeIdentity = .current,
        executablePathProvider: @escaping () -> String = { CommandLine.arguments.first ?? "" },
        fileManager: FileManager = .default
    ) {
        self.identity = identity
        self.executablePathProvider = executablePathProvider
        self.fileManager = fileManager
    }

    func runningApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: self.identity.bundleIdentifier).first
    }

    func installedAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: self.identity.bundleIdentifier)
    }

    func appVersion(bundleURL: URL?) -> String? {
        guard let bundleURL else { return nil }
        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleShortVersionString"] as? String
    }

    func helperOwningAppURL(executablePath: String? = nil) -> URL? {
        let path = executablePath ?? self.executablePathProvider()
        guard path.isEmpty == false else { return nil }

        var candidates = [URL(fileURLWithPath: path)]
        if let resolved = self.resolvedSymlinkURL(from: path) {
            candidates.insert(resolved, at: 0)
        }

        for candidate in candidates {
            if let appURL = self.containingAppURL(for: candidate) {
                return appURL
            }
        }
        return nil
    }

    func preferredRoutingAppURL() -> URL? {
        let candidates = [
            self.helperOwningAppURL(),
            self.runningApp()?.bundleURL,
            self.installedAppURL(),
        ]

        return candidates.compactMap { $0 }.first { self.matchesIdentity(bundleURL: $0) }
    }

    private func containingAppURL(for executableURL: URL) -> URL? {
        var cursor = executableURL.standardizedFileURL.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.pathExtension.lowercased() == "app" {
                return cursor
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private func matchesIdentity(bundleURL: URL) -> Bool {
        self.bundleIdentifier(bundleURL: bundleURL) == self.identity.bundleIdentifier
    }

    private func bundleIdentifier(bundleURL: URL) -> String? {
        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let plist = NSDictionary(contentsOf: infoPlistURL) as? [String: Any] else {
            return nil
        }
        return plist["CFBundleIdentifier"] as? String
    }

    private func resolvedSymlinkURL(from path: String) -> URL? {
        do {
            let destination = try self.fileManager.destinationOfSymbolicLink(atPath: path)
            if destination.hasPrefix("/") {
                return URL(fileURLWithPath: destination)
            }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            return parent.appendingPathComponent(destination)
        } catch {
            return nil
        }
    }
}
