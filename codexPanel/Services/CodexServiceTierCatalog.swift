import Foundation

/// Codex 自己维护的模型目录缓存（`~/.codex/models_cache.json`）中与服务档位相关的部分。
///
/// CodexPanel 只读消费这份缓存，让菜单选项和写入 config.toml 的档位跟随 Codex
/// 后端自动调整，而不是维护一份容易过期的模型名单。
struct CodexServiceTierCatalog: Equatable {
    struct Tier: Equatable, Hashable {
        let id: String
        let name: String
        let description: String
    }

    struct Model: Equatable {
        let slug: String
        let defaultServiceTier: String?
        let serviceTiers: [Tier]
    }

    let models: [Model]
    let fetchedAt: Date?

    static func load(from url: URL = CodexPaths.modelsCacheURL) -> CodexServiceTierCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.parse(data)
    }

    static func parse(_ data: Data) throws -> CodexServiceTierCatalog {
        let payload = try JSONDecoder().decode(CachePayload.self, from: data)
        let models = payload.models.compactMap { entry -> Model? in
            guard let slug = Self.normalizedModelID(entry.slug) else { return nil }
            let tiers = (entry.serviceTiers ?? []).compactMap { tier -> Tier? in
                let id = tier.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard id.isEmpty == false else { return nil }
                return Tier(
                    id: id,
                    name: tier.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? id,
                    description: tier.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            }
            let defaultTier = entry.defaultServiceTier?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return Model(
                slug: slug,
                defaultServiceTier: defaultTier?.isEmpty == false ? defaultTier : nil,
                serviceTiers: Self.uniqueTiers(tiers)
            )
        }
        return CodexServiceTierCatalog(
            models: models,
            fetchedAt: payload.fetchedAt.flatMap(Self.parseDate)
        )
    }

    func model(for modelID: String) -> Model? {
        guard let normalized = Self.normalizedModelID(modelID) else { return nil }
        return self.models.first { $0.slug == normalized }
    }

    func serviceTierOptions(for modelID: String) -> [String]? {
        guard let model = self.model(for: modelID) else { return nil }
        var options = [CodexPanelGlobalSettings.standardServiceTier]
        for tier in model.serviceTiers {
            let value = CodexPanelGlobalSettings.serviceTierValue(forCatalogTierID: tier.id)
            if options.contains(value) == false {
                options.append(value)
            }
        }
        return options
    }

    private struct CachePayload: Decodable {
        let fetchedAt: String?
        let models: [ModelEntry]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case models
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt)
            if let list = try? container.decode([LossyModelEntry].self, forKey: .models) {
                self.models = list.compactMap(\.entry)
            } else if let keyed = try? container.decode([String: LossyModelEntry].self, forKey: .models) {
                self.models = keyed.compactMap(\.value.entry)
            } else {
                self.models = []
            }
        }
    }

    private struct LossyModelEntry: Decodable {
        let entry: ModelEntry?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.entry = try? container.decode(ModelEntry.self)
        }
    }

    private struct ModelEntry: Decodable {
        let slug: String
        let defaultServiceTier: String?
        let serviceTiers: [TierEntry]?

        enum CodingKeys: String, CodingKey {
            case slug
            case defaultServiceTier = "default_service_tier"
            case serviceTiers = "service_tiers"
        }
    }

    private struct TierEntry: Decodable {
        let id: String
        let name: String?
        let description: String?
    }

    private static func normalizedModelID(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func uniqueTiers(_ tiers: [Tier]) -> [Tier] {
        var seen: Set<String> = []
        return tiers.filter { seen.insert($0.id).inserted }
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }
}
