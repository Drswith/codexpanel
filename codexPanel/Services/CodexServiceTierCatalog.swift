import Foundation

/// Codex 的模型目录；缓存与 model/list 共用同一能力模型。
/// 旧名称保留为别名，让配置同步的服务档位契约继续复用这份目录。
typealias CodexServiceTierCatalog = CodexModelCatalog

struct CodexModelCatalog: Equatable, Codable, Sendable {
    nonisolated struct Tier: Equatable, Hashable, Codable, Sendable {
        let id: String
        let name: String
        let description: String
    }

    nonisolated struct Model: Equatable, Codable, Sendable {
        let slug: String
        var displayName: String? = nil
        var hidden: Bool = false
        var reasoningEfforts: [String]? = nil
        var defaultReasoningEffort: String? = nil
        var defaultServiceTier: String? = nil
        var serviceTiers: [Tier] = []
        var hasServiceTierMetadata: Bool = true
    }

    nonisolated let models: [Model]
    nonisolated let fetchedAt: Date?
    nonisolated let identity: String?

    nonisolated init(models: [Model], fetchedAt: Date?, identity: String? = nil) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.identity = identity
    }

    nonisolated static let fallbackModelIDs = [
        "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
        "gpt-5.6", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-5.5", "gpt-5.4", "gpt-5.4-mini",
    ]

    static func load() -> CodexModelCatalog? {
        Self.load(from: CodexPaths.modelsCacheURL)
    }

    static func load(from url: URL) -> CodexModelCatalog? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.parse(data)
    }

    nonisolated static func parse(_ data: Data) throws -> CodexModelCatalog {
        let payload = try JSONDecoder().decode(CachePayload.self, from: data)
        return CodexModelCatalog(models: Self.uniqueModels(payload.models.compactMap { entry in
            guard let slug = Self.trimmed(entry.slug) else { return nil }
            return Model(
                slug: slug,
                displayName: Self.trimmed(entry.displayName),
                hidden: entry.visibility == "hide",
                reasoningEfforts: entry.reasoningLevels.map { Self.uniqueStrings($0.map(\.effort)) },
                defaultReasoningEffort: Self.trimmed(entry.defaultReasoningLevel),
                defaultServiceTier: Self.trimmed(entry.defaultServiceTier),
                serviceTiers: Self.uniqueTiers((entry.serviceTiers ?? []).compactMap { tier in
                    guard let id = Self.trimmed(tier.id)?.lowercased() else { return nil }
                    return Tier(id: id, name: Self.trimmed(tier.name) ?? id, description: tier.description ?? "")
                }),
                hasServiceTierMetadata: entry.serviceTiers != nil
            )
        }), fetchedAt: payload.fetchedAt.flatMap(ISO8601Parsing.parse), identity: payload.identity)
    }

    nonisolated func model(for modelID: String) -> Model? {
        let id = modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = self.models.first(where: { $0.slug.lowercased() == id }) { return exact }
        // 只做查询兼容，不改写用户配置或目录里的原始 ID。
        let alias = id == "gpt-5.6" ? "gpt-5.6-sol" : (id == "gpt-5.6-sol" ? "gpt-5.6" : id)
        return self.models.first { $0.slug.lowercased() == alias }
    }

    nonisolated func selectionOptions(currentModel: String) -> [String] {
        let visible = self.models.filter { !$0.hidden }.map(\.slug)
        // 有效目录中的隐藏项不重新混入；无可选模型时才启用内置兜底。
        let candidates = visible.isEmpty ? Self.fallbackModelIDs : visible
        return Self.uniqueStrings(candidates + [currentModel])
    }

    nonisolated func displayName(for modelID: String) -> String {
        self.model(for: modelID)?.displayName ?? Self.fallbackDisplayName(for: modelID)
    }

    nonisolated static func fallbackDisplayName(for modelID: String) -> String {
        switch modelID {
        case "gpt-6.1-sol": return "GPT-6.1 Sol"
        case "gpt-6-astra": return "GPT-6 Astra"
        case "gpt-6-sol": return "GPT-6 Sol"
        case "gpt-6-luna": return "GPT-6 Luna"
        case "gpt-5.6", "gpt-5.6-sol": return "5.6 Sol"
        case "gpt-5.6-terra": return "5.6 Terra"
        case "gpt-5.6-luna": return "5.6 Luna"
        case "gpt-5.5": return "5.5"
        case "gpt-5.4": return "5.4"
        case "gpt-5.4-mini": return "5.4 Mini"
        default: return modelID
        }
    }

    nonisolated func serviceTierOptions(for modelID: String) -> [String]? {
        guard let model = self.model(for: modelID), model.hasServiceTierMetadata else { return nil }
        return Self.uniqueStrings(["standard"] + model.serviceTiers.map { $0.id == "priority" ? "fast" : $0.id })
    }

    nonisolated func reasoningEffortOptions(for modelID: String) -> [String]? {
        guard let options = self.model(for: modelID)?.reasoningEfforts, !options.isEmpty else { return nil }
        return options
    }

    /// model/list 不包含服务档位时，保留 Codex 缓存提供的相关字段。
    nonisolated func mergingServiceTiers(from cache: CodexModelCatalog?) -> CodexModelCatalog {
        if let identity = self.identity, let cacheIdentity = cache?.identity, identity != cacheIdentity { return self }
        return CodexModelCatalog(models: self.models.map { entry in
            guard !entry.hasServiceTierMetadata, let cached = cache?.model(for: entry.slug) else { return entry }
            var result = entry
            result.serviceTiers = cached.serviceTiers
            result.defaultServiceTier = cached.defaultServiceTier
            result.hasServiceTierMetadata = cached.hasServiceTierMetadata
            return result
        }, fetchedAt: self.fetchedAt, identity: self.identity ?? cache?.identity)
    }

    nonisolated static func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let value = Self.trimmed(value), seen.insert(value).inserted else { return nil }
            return value
        }
    }

    nonisolated private static func uniqueModels(_ values: [Model]) -> [Model] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.slug).inserted }
    }

    nonisolated private static func uniqueTiers(_ values: [Tier]) -> [Tier] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.id).inserted }
    }

    nonisolated private static func trimmed(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    nonisolated private struct CachePayload: Decodable {
        let fetchedAt: String?
        let identity: String?
        let models: [ModelEntry]
        enum CodingKeys: String, CodingKey { case fetchedAt = "fetched_at", identity, models }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.fetchedAt = try container.decodeIfPresent(String.self, forKey: .fetchedAt)
            self.identity = try container.decodeIfPresent(String.self, forKey: .identity)
            if let list = try? container.decode([LossyModelEntry].self, forKey: .models) {
                self.models = list.compactMap(\.entry)
            } else if let keyed = try? container.decode([String: LossyModelEntry].self, forKey: .models) {
                self.models = keyed.keys.sorted().compactMap { keyed[$0]?.entry }
            } else {
                throw DecodingError.dataCorruptedError(forKey: .models, in: container, debugDescription: "Invalid model catalog")
            }
        }
    }

    nonisolated private struct LossyModelEntry: Decodable {
        let entry: ModelEntry?
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self.entry = try? container.decode(ModelEntry.self)
        }
    }

    nonisolated private struct ModelEntry: Decodable {
        let slug: String
        let displayName: String?
        let visibility: String?
        let reasoningLevels: [ReasoningLevel]?
        let defaultReasoningLevel: String?
        let defaultServiceTier: String?
        let serviceTiers: [TierEntry]?
        enum CodingKeys: String, CodingKey {
            case slug, visibility
            case displayName = "display_name"
            case reasoningLevels = "supported_reasoning_levels"
            case defaultReasoningLevel = "default_reasoning_level"
            case defaultServiceTier = "default_service_tier"
            case serviceTiers = "service_tiers"
        }
    }
    nonisolated private struct ReasoningLevel: Decodable { let effort: String }
    nonisolated private struct TierEntry: Decodable { let id: String; let name: String?; let description: String? }
}
