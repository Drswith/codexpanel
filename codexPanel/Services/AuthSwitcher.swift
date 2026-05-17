import Foundation

/// 将指定账号写入当前 profile 的 auth.json，供 Codex CLI/App 使用。
struct AuthSwitcher {
    static var authFilePath: URL { CodexPaths.authURL }

    static func activate(_ account: TokenAccount) throws {
        let dir = self.authFilePath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 读取现有文件，保留非 token 字段
        var existing: [String: Any] = [:]
        if let data = try? Data(contentsOf: self.authFilePath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            existing = json
        }

        existing["auth_mode"] = "chatgpt"
        existing["OPENAI_API_KEY"] = NSNull()
        existing["tokens"] = [
            "access_token": account.accessToken,
            "refresh_token": account.refreshToken,
            "id_token": account.idToken,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]

        let data = try JSONSerialization.data(withJSONObject: existing, options: [.prettyPrinted, .sortedKeys])
        try CodexPaths.writeSecureFile(data, to: self.authFilePath)
    }

    /// 读取当前激活账号的 email（用于标记 isActive）
    static func currentEmail() -> String? {
        guard let data = try? Data(contentsOf: self.authFilePath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String else { return nil }
        let claims = AccountBuilder.decodeJWT(accessToken)
        let profile = claims["https://api.openai.com/profile"] as? [String: Any]
        return profile?["email"] as? String
    }
}
