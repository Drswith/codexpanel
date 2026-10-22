import Foundation

// 旧统计口径只用于兼容性测试，生产用量统一由 tokscale 提供。
struct LocalCostSummaryService {
    private struct SummaryAccumulator {
        var today: Double = 0
        var last30: Double = 0
        var lifetime: Double = 0
        var todayTokens = 0
        var last30Tokens = 0
        var lifetimeTokens = 0
        var daily: [Date: (cost: Double, tokens: Int)] = [:]
    }

    private let sessionLogStore: SessionLogStore
    private let calendar: Calendar

    init(
        sessionLogStore: SessionLogStore = .shared,
        calendar: Calendar = .current
    ) {
        self.sessionLogStore = sessionLogStore
        self.calendar = calendar
    }

    func historicalModels(refreshSessionCache: Bool = false) -> [String] {
        self.sessionLogStore.historicalModels(refreshSessionCache: refreshSessionCache)
    }

    func load(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexPanelModelPricing] = [:],
        refreshSessionCache: Bool = true
    ) -> LocalCostSummary {
        let todayStart = self.calendar.startOfDay(for: now)
        let last30Start = self.calendar.date(byAdding: .day, value: -29, to: todayStart) ?? todayStart

        let summary = self.sessionLogStore.reduceBillableEvents(
            into: SummaryAccumulator(),
            refreshSessionCache: refreshSessionCache,
            costCalculator: { model, usage, sessionUsage in
                LocalCostPricing.costUSD(
                    model: model,
                    usage: usage,
                    sessionUsage: sessionUsage,
                    customPricingByModel: modelPricingOverrides
                )
            }
        ) { accumulator, event in
            let totalTokens = event.usage.totalTokens
            let day = self.calendar.startOfDay(for: event.timestamp)

            if event.timestamp >= last30Start {
                accumulator.last30 += event.costUSD
                accumulator.last30Tokens += totalTokens
            }
            if event.timestamp >= todayStart {
                accumulator.today += event.costUSD
                accumulator.todayTokens += totalTokens
            }

            accumulator.lifetime += event.costUSD
            accumulator.lifetimeTokens += totalTokens

            let current = accumulator.daily[day] ?? (0, 0)
            accumulator.daily[day] = (current.cost + event.costUSD, current.tokens + totalTokens)
        }

        let dailyEntries = summary.daily.map { date, value in
            DailyCostEntry(
                id: ISO8601DateFormatter().string(from: date),
                date: date,
                costUSD: value.cost,
                totalTokens: value.tokens
            )
        }.sorted { $0.date > $1.date }

        return LocalCostSummary(
            todayCostUSD: summary.today,
            todayTokens: summary.todayTokens,
            last30DaysCostUSD: summary.last30,
            last30DaysTokens: summary.last30Tokens,
            lifetimeCostUSD: summary.lifetime,
            lifetimeTokens: summary.lifetimeTokens,
            dailyEntries: dailyEntries,
            updatedAt: now
        )
    }
}

extension LocalCostSummaryService: LocalCostSummaryProviding {
    func setEngine(_ engine: TokscaleEngineDescriptor?) {}

    func load(now: Date, modelPricingOverrides: [String: CodexPanelModelPricing]) -> LocalCostSummary {
        var summary = self.load(now: now, modelPricingOverrides: modelPricingOverrides, refreshSessionCache: true)
        summary.historicalModels = self.historicalModels()
        return summary
    }
}
