import Foundation

/// 用量界面的数据边界。生产实现使用用户选择的 tokscale。
protocol LocalCostSummaryProviding {
    func setEngine(_ engine: TokscaleEngineDescriptor?)

    func load(
        now: Date,
        modelPricingOverrides: [String: CodexPanelModelPricing]
    ) throws -> LocalCostSummary
}
