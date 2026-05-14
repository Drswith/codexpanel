import Foundation

enum CLISnapshotRedactor {
    private static let sensitiveKeywords = [
        "token",
        "api key",
        "apikey",
        "password",
        "secret",
        "authorization",
        "bearer",
        "refresh_token",
        "access_token",
        "id_token",
    ]

    static func redact(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        let lower = trimmed.lowercased()
        if self.sensitiveKeywords.contains(where: { lower.contains($0) }) {
            return "<redacted>"
        }
        if lower.hasPrefix("sk-") || lower.hasPrefix("sess-") {
            return "<redacted>"
        }
        if self.looksLikeLongTokenOrJWT(trimmed, lowercased: lower) {
            return "<redacted>"
        }
        return trimmed
    }

    private static func looksLikeLongTokenOrJWT(_ value: String, lowercased: String) -> Bool {
        if value.count > 48, lowercased.contains(".") {
            return true
        }
        let compact = value.replacingOccurrences(of: " ", with: "")
        let jwtParts = compact.split(separator: ".")
        if jwtParts.count == 3, jwtParts.allSatisfy({ $0.count >= 8 }) {
            return true
        }
        return false
    }
}

enum CLISnapshotRefBuilder {
    static func windowRef(identifier: String?, title: String?, kind: SnapshotTarget) -> String {
        if let identifier, identifier.isEmpty == false {
            return "@\(identifier)"
        }
        let titleSlug = self.slug(title ?? kind.rawValue)
        return "@window.\(titleSlug)"
    }

    static func childRef(
        identifier: String?,
        role: String,
        title: String?,
        label: String?,
        parentRef: String,
        siblingCounter: inout [String: Int]
    ) -> String {
        if let identifier, identifier.isEmpty == false {
            return "@\(identifier)"
        }
        let base = self.slug(identifier ?? title ?? label ?? role)
        let count = (siblingCounter[base] ?? 0) + 1
        siblingCounter[base] = count
        return "\(parentRef)/\(base).\(count)"
    }

    static func slug(_ source: String) -> String {
        let allowed = source.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        let raw = String(allowed)
        let collapsed = raw.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "node" : trimmed
    }
}

