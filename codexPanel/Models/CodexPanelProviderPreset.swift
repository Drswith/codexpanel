import Foundation

/// Vendor-specific quirks the chat/completions translation gateway must honour.
///
/// Defaults match the most common OpenAI-compatible behaviour. Individual presets
/// override only the fields where the upstream deviates from that baseline.
struct CodexPanelChatQuirks: Equatable {
    /// Path appended to the provider `baseURL` to reach the chat completions endpoint.
    var chatCompletionsPathSuffix: String
    /// Field name used to cap output tokens (`max_tokens` vs `max_completion_tokens`).
    var maxTokensField: String
    /// Flatten structured content arrays into a single string (some GLM endpoints require this).
    var flattenContent: Bool
    /// Downgrade an explicit `tool_choice` object to `"auto"` (GLM rejects forced tool choice).
    var toolChoiceDowngradeToAuto: Bool
    /// Upstream emits `reasoning_content` deltas (DeepSeek-R1, Kimi thinking, GLM thinking…).
    var supportsReasoning: Bool

    init(
        chatCompletionsPathSuffix: String = "/chat/completions",
        maxTokensField: String = "max_tokens",
        flattenContent: Bool = false,
        toolChoiceDowngradeToAuto: Bool = false,
        supportsReasoning: Bool = true
    ) {
        self.chatCompletionsPathSuffix = chatCompletionsPathSuffix
        self.maxTokensField = maxTokensField
        self.flattenContent = flattenContent
        self.toolChoiceDowngradeToAuto = toolChoiceDowngradeToAuto
        self.supportsReasoning = supportsReasoning
    }

    static let standard = CodexPanelChatQuirks()
}

enum CodexPanelProviderPresetGroup: String, CaseIterable, Identifiable {
    case domestic
    case foreign

    var id: String { self.rawValue }

    var title: String {
        switch self {
        case .domestic:
            return L.providerPresetGroupDomestic
        case .foreign:
            return L.providerPresetGroupForeign
        }
    }
}

enum CodexPanelProviderPresetKind: Equatable {
    case openAICompatible
    case openRouter
}

struct CodexPanelProviderPreset: Identifiable, Equatable {
    let id: String
    let displayName: String
    let group: CodexPanelProviderPresetGroup
    let kind: CodexPanelProviderPresetKind
    let baseURL: String
    let wireAPI: CodexPanelWireAPI
    let quirks: CodexPanelChatQuirks
    /// Optional advisory shown in the UI (e.g. native protocol caveats).
    let note: String?

    init(
        id: String,
        displayName: String,
        group: CodexPanelProviderPresetGroup,
        kind: CodexPanelProviderPresetKind = .openAICompatible,
        baseURL: String,
        wireAPI: CodexPanelWireAPI = .chat,
        quirks: CodexPanelChatQuirks = .standard,
        note: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.group = group
        self.kind = kind
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.quirks = quirks
        self.note = note
    }

}

enum CodexPanelProviderPresetCatalog {
    static let all: [CodexPanelProviderPreset] = domestic + foreign

    static let domestic: [CodexPanelProviderPreset] = [
        CodexPanelProviderPreset(
            id: "deepseek",
            displayName: "DeepSeek",
            group: .domestic,
            baseURL: "https://api.deepseek.com/v1"
        ),
        CodexPanelProviderPreset(
            id: "zhipu-glm",
            displayName: "智谱 GLM",
            group: .domestic,
            baseURL: "https://open.bigmodel.cn/api/paas/v4",
            quirks: CodexPanelChatQuirks(
                flattenContent: true,
                toolChoiceDowngradeToAuto: true
            )
        ),
        CodexPanelProviderPreset(
            id: "moonshot-kimi",
            displayName: "Kimi (月之暗面)",
            group: .domestic,
            baseURL: "https://api.moonshot.cn/v1",
            quirks: CodexPanelChatQuirks(maxTokensField: "max_completion_tokens")
        ),
        CodexPanelProviderPreset(
            id: "qwen-dashscope",
            displayName: "通义千问 (百炼)",
            group: .domestic,
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"
        ),
        CodexPanelProviderPreset(
            id: "minimax",
            displayName: "MiniMax",
            group: .domestic,
            baseURL: "https://api.minimaxi.com/v1",
            quirks: CodexPanelChatQuirks(maxTokensField: "max_completion_tokens")
        ),
        CodexPanelProviderPreset(
            id: "doubao-ark",
            displayName: "豆包 (火山方舟)",
            group: .domestic,
            baseURL: "https://ark.cn-beijing.volces.com/api/v3",
            note: L.providerPresetNoteArkEndpoint
        ),
        CodexPanelProviderPreset(
            id: "siliconflow",
            displayName: "硅基流动 SiliconFlow",
            group: .domestic,
            baseURL: "https://api.siliconflow.cn/v1"
        ),
        CodexPanelProviderPreset(
            id: "stepfun",
            displayName: "阶跃星辰 StepFun",
            group: .domestic,
            baseURL: "https://api.stepfun.com/v1"
        ),
        CodexPanelProviderPreset(
            id: "lingyiwanwu",
            displayName: "零一万物 Yi",
            group: .domestic,
            baseURL: "https://api.lingyiwanwu.com/v1"
        ),
        CodexPanelProviderPreset(
            id: "hunyuan",
            displayName: "腾讯混元",
            group: .domestic,
            baseURL: "https://api.hunyuan.cloud.tencent.com/v1"
        ),
        CodexPanelProviderPreset(
            id: "spark",
            displayName: "讯飞星火",
            group: .domestic,
            baseURL: "https://spark-api-open.xf-yun.com/v1"
        ),
        CodexPanelProviderPreset(
            id: "baichuan",
            displayName: "百川 Baichuan",
            group: .domestic,
            baseURL: "https://api.baichuan-ai.com/v1"
        ),
    ]

    static let foreign: [CodexPanelProviderPreset] = [
        CodexPanelProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            group: .foreign,
            kind: .openRouter,
            baseURL: "https://openrouter.ai/api/v1",
            wireAPI: .responses
        ),
        CodexPanelProviderPreset(
            id: "openai-apikey",
            displayName: "OpenAI (API Key)",
            group: .foreign,
            baseURL: "https://api.openai.com/v1",
            wireAPI: .responses
        ),
        CodexPanelProviderPreset(
            id: "groq",
            displayName: "Groq",
            group: .foreign,
            baseURL: "https://api.groq.com/openai/v1"
        ),
        CodexPanelProviderPreset(
            id: "xai",
            displayName: "xAI Grok",
            group: .foreign,
            baseURL: "https://api.x.ai/v1"
        ),
        CodexPanelProviderPreset(
            id: "mistral",
            displayName: "Mistral",
            group: .foreign,
            baseURL: "https://api.mistral.ai/v1"
        ),
        CodexPanelProviderPreset(
            id: "together",
            displayName: "Together AI",
            group: .foreign,
            baseURL: "https://api.together.xyz/v1"
        ),
        CodexPanelProviderPreset(
            id: "fireworks",
            displayName: "Fireworks AI",
            group: .foreign,
            baseURL: "https://api.fireworks.ai/inference/v1"
        ),
        CodexPanelProviderPreset(
            id: "deepinfra",
            displayName: "DeepInfra",
            group: .foreign,
            baseURL: "https://api.deepinfra.com/v1/openai"
        ),
        CodexPanelProviderPreset(
            id: "perplexity",
            displayName: "Perplexity",
            group: .foreign,
            baseURL: "https://api.perplexity.ai"
        ),
        CodexPanelProviderPreset(
            id: "gemini-openai",
            displayName: "Gemini (OpenAI 兼容)",
            group: .foreign,
            baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
            note: L.providerPresetNoteGeminiCompat
        ),
    ]

    static func preset(id: String?) -> CodexPanelProviderPreset? {
        guard let id, id.isEmpty == false else { return nil }
        return self.all.first { $0.id == id }
    }

    /// Resolve the chat quirks for a provider, falling back to the standard
    /// OpenAI-compatible behaviour for custom (preset-less) providers.
    static func quirks(forPresetID presetID: String?) -> CodexPanelChatQuirks {
        self.preset(id: presetID)?.quirks ?? .standard
    }
}
