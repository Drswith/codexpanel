import Foundation

struct CLISnapshotWindowMetadata: Equatable {
    var identifier: String?
    var title: String?
    var kind: SnapshotTarget
}

enum CLISnapshotWindowSelectionCore {
    static func classifyWindow(identifier: String?, title: String?) -> SnapshotTarget {
        let normalizedIdentifier = identifier?.lowercased() ?? ""
        let normalizedTitle = title?.lowercased() ?? ""

        if normalizedIdentifier == settingsWindowIdentifier || normalizedIdentifier.contains("openai-settings") {
            return .settings
        }
        if normalizedIdentifier == loginWindowIdentifier || normalizedIdentifier.contains("oauth-login") {
            return .login
        }
        if normalizedIdentifier == menuWindowIdentifier || normalizedIdentifier.contains("status-item-menu") {
            return .menu
        }
        if normalizedTitle.contains("setting") {
            return .settings
        }
        if normalizedTitle.contains("oauth") || normalizedTitle.contains("login") {
            return .login
        }
        return .all
    }

    static func selectWindowIndices(_ windows: [CLISnapshotWindowMetadata], target: SnapshotTarget) -> [Int] {
        if windows.isEmpty {
            return []
        }

        switch target {
        case .all:
            return Array(windows.indices)
        case .settings:
            return windows.indices.filter { windows[$0].kind == .settings }
        case .menu:
            return windows.indices.filter { windows[$0].kind == .menu }
        case .login:
            return windows.indices.filter { windows[$0].kind == .login }
        case .auto:
            let preferred: [SnapshotTarget] = [.settings, .menu, .login]
            for item in preferred {
                let match = windows.indices.filter { windows[$0].kind == item }
                if match.isEmpty == false {
                    return match
                }
            }
            return Array(windows.indices)
        }
    }

    static func autoResolvedTarget(for windows: [CLISnapshotWindowMetadata]) -> SnapshotTarget {
        if windows.contains(where: { $0.kind == .settings }) {
            return .settings
        }
        if windows.contains(where: { $0.kind == .menu }) {
            return .menu
        }
        if windows.contains(where: { $0.kind == .login }) {
            return .login
        }
        return .all
    }
}
