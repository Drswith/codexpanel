import Foundation

/// 本地会话统计独立于账号的远端额度查询；旧配置升级后保持关闭。
struct CodexPanelLocalUsageSettings: Codable, Equatable {
    var enabled: Bool = false
    var preferredSource: TokscaleEngineSource = .installed
    var installedExecutablePath: String? = nil

    init(enabled: Bool = false, preferredSource: TokscaleEngineSource = .installed, installedExecutablePath: String? = nil) {
        self.enabled = enabled
        self.preferredSource = preferredSource
        self.installedExecutablePath = installedExecutablePath
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, preferredSource, installedExecutablePath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.preferredSource = try values.decodeIfPresent(TokscaleEngineSource.self, forKey: .preferredSource) ?? .installed
        self.installedExecutablePath = try values.decodeIfPresent(String.self, forKey: .installedExecutablePath)
    }
}
