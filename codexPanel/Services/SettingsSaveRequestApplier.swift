import Foundation

enum SettingsSaveRequestApplier {
    static func apply(
        _ requests: SettingsSaveRequests,
        to config: inout CodexPanelConfig
    ) throws {
        self.apply(requests.global, to: &config)
        self.apply(requests.openAIAccount, to: &config)
        self.apply(requests.openAIUsage, to: &config)
        self.apply(requests.modelPricing, to: &config)
        try self.apply(requests.desktop, to: &config)
    }

    static func apply(_ request: GlobalSettingsUpdate?, to config: inout CodexPanelConfig) {
        guard let request else { return }
        let defaultModel = self.normalizedModel(request.defaultModel) ?? config.global.defaultModel
        let reviewModel = self.normalizedModel(request.reviewModel) ?? defaultModel
        let reasoningEffort = self.normalizedReasoningEffort(request.reasoningEffort) ?? config.global.reasoningEffort
        config.global = CodexPanelGlobalSettings(
            defaultModel: defaultModel,
            reviewModel: reviewModel,
            reasoningEffort: reasoningEffort
        )
    }

    static func apply(_ request: OpenAIAccountSettingsUpdate?, to config: inout CodexPanelConfig) {
        guard let request else { return }
        config.setOpenAIAccountOrder(request.accountOrder)
        config.setOpenAIAccountUsageMode(request.accountUsageMode)
        config.setOpenAIAccountOrderingMode(request.accountOrderingMode)
        config.setOpenAIManualActivationBehavior(request.manualActivationBehavior)
    }

    static func apply(_ request: OpenAIUsageSettingsUpdate?, to config: inout CodexPanelConfig) {
        guard let request else { return }
        config.openAI.usageDisplayMode = request.usageDisplayMode
        config.openAI.quotaSort = CodexPanelOpenAISettings.QuotaSortSettings(
            plusRelativeWeight: request.plusRelativeWeight,
            proRelativeToPlusMultiplier: request.proRelativeToPlusMultiplier,
            teamRelativeToPlusMultiplier: request.teamRelativeToPlusMultiplier
        )
    }

    static func apply(_ request: ModelPricingSettingsUpdate?, to config: inout CodexPanelConfig) {
        guard let request else { return }

        for model in request.removals {
            config.modelPricing.removeValue(forKey: model)
        }

        for (model, pricing) in request.upserts {
            config.modelPricing[model] = pricing
        }
    }

    static func apply(_ request: DesktopSettingsUpdate?, to config: inout CodexPanelConfig) throws {
        guard let request else { return }
        config.desktop.preferredCodexAppPath = try self.validatedPreferredCodexAppPath(
            from: request.preferredCodexAppPath
        )
    }

    static func validatedPreferredCodexAppPath(from preferredCodexAppPath: String?) throws -> String? {
        let trimmedPreferredPath = preferredCodexAppPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedPreferredPath.isEmpty {
            return nil
        }

        guard let validatedPath = CodexDesktopLaunchProbeService
            .validatedPreferredCodexAppURL(from: trimmedPreferredPath)?
            .path else {
            throw TokenStoreError.invalidCodexAppPath
        }

        return validatedPath
    }

    private static func normalizedModel(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedReasoningEffort(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
