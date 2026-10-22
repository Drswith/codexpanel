import SwiftUI

enum LocalCostPresentation {
    static func statusText(summary: LocalCostSummary, refreshError: String?, isRefreshing: Bool) -> String? {
        if refreshError != nil {
            return summary.updatedAt == nil ? "用量暂不可用" : "更新失败，显示上次结果"
        }
        if isRefreshing {
            return summary.updatedAt == nil ? "正在统计用量…" : "正在更新用量…"
        }
        guard summary.updatedAt != nil else { return "等待统计用量" }
        if summary.source == nil {
            return "旧版缓存，等待重新统计"
        }
        if !summary.todayCostIsComplete || !summary.last30DaysCostIsComplete || !summary.lifetimeCostIsComplete {
            return "部分用量缺少价格"
        }
        return nil
    }

    static func costText(
        cost: Double,
        isComplete: Bool,
        hasResult: Bool,
        currency: (Double) -> String
    ) -> String {
        guard hasResult else { return "—" }
        guard isComplete else { return cost > 0 ? "≥\(currency(cost))" : "价格未知" }
        return currency(cost)
    }

    static func explanation(summary: LocalCostSummary, refreshError: String?) -> String {
        var details: [String] = []
        if let refreshError { details.append(refreshError) }
        if summary.source == nil, summary.updatedAt != nil {
            details.append("当前显示旧版统计缓存，更新完成后将按新口径重新计算。")
        } else {
            let timeZone = summary.bucketTimeZoneIdentifier ?? TimeZone.current.identifier
            details.append("按请求开始时间归属日期（\(timeZone)）。")
        }
        if !summary.todayCostIsComplete || !summary.last30DaysCostIsComplete || !summary.lifetimeCostIsComplete {
            details.append("部分模型缺少价格；金额仅包含已知价格的用量，token 总量仍然完整。")
        }
        return details.joined(separator: "\n")
    }

    static func chartEntries(summary: LocalCostSummary) -> [DailyCostEntry] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = summary.bucketTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current
        let end = calendar.startOfDay(for: summary.updatedAt ?? Date())
        let start = calendar.date(byAdding: .day, value: -29, to: end) ?? end
        return summary.dailyEntries.filter { $0.date >= start && $0.date <= end }.sorted { $0.date < $1.date }
    }
}

struct CostSummaryRowView: View {
    let summary: LocalCostSummary
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    var refreshError: String? = nil
    var isRefreshing: Bool = false

    private var statusText: String? {
        LocalCostPresentation.statusText(summary: summary, refreshError: refreshError, isRefreshing: isRefreshing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cost")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if isRefreshing {
                    ProgressView().controlSize(.mini)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            Text(metricText(title: "Today", cost: summary.todayCostUSD, tokens: summary.todayTokens, isComplete: summary.todayCostIsComplete))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Text(metricText(title: "Last 30 days", cost: summary.last30DaysCostUSD, tokens: summary.last30DaysTokens, isComplete: summary.last30DaysCostIsComplete))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if let statusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(refreshError == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, MenuBarPopoverSizing.sectionHorizontalInset)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
        )
        .help(LocalCostPresentation.explanation(summary: summary, refreshError: refreshError))
    }

    private func metricText(title: String, cost: Double, tokens: Int, isComplete: Bool) -> String {
        let value = LocalCostPresentation.costText(
            cost: cost, isComplete: isComplete, hasResult: summary.updatedAt != nil, currency: currency
        )
        let tokenValue = summary.updatedAt == nil ? "—" : compactTokens(tokens)
        return "\(title): \(value) · \(tokenValue) tokens"
    }
}

struct CostDetailsPanelView: View {
    static let panelWidth: CGFloat = 272

    static func panelHeight(hasHistory: Bool, hasStatus: Bool = false) -> CGFloat {
        (hasHistory ? 336 : 184) + (hasStatus ? 24 : 0)
    }

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let costUSD: Double
        let totalTokens: Int
        let costIsComplete: Bool
    }

    private struct MiniBarChart: View {
        let points: [Point]
        @Binding var selectedID: String?

        private let minBarHeight: CGFloat = 6
        private let barSpacing: CGFloat = 4

        var body: some View {
            GeometryReader { geometry in
                let maxCost = max(points.map(\.costUSD).max() ?? 0, 0.01)
                let slotWidth = geometry.size.width / CGFloat(Swift.max(points.count, 1))

                HStack(alignment: .bottom, spacing: barSpacing) {
                    ForEach(points) { point in
                        let isSelected = selectedID == point.id
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor : Color.accentColor.opacity(0.68))
                            .frame(maxWidth: .infinity)
                            .frame(height: self.barHeight(for: point, totalHeight: geometry.size.height, maxCost: maxCost))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard points.isEmpty == false,
                              location.x >= 0,
                              location.x <= geometry.size.width else {
                            selectedID = nil
                            return
                        }

                        let index = min(max(Int(location.x / max(slotWidth, 1)), 0), points.count - 1)
                        selectedID = points[index].id
                    case .ended:
                        selectedID = nil
                    }
                }
            }
            .frame(height: 128)
        }

        private func barHeight(for point: Point, totalHeight: CGFloat, maxCost: Double) -> CGFloat {
            guard totalHeight > 0 else { return minBarHeight }
            let usableHeight = max(totalHeight - 4, minBarHeight)
            let ratio = point.costUSD > 0 ? CGFloat(point.costUSD / maxCost) : 0
            return max(minBarHeight, usableHeight * ratio)
        }
    }

    let summary: LocalCostSummary
    let currency: (Double) -> String
    let compactTokens: (Int) -> String
    let shortDay: (Date) -> String
    var refreshError: String? = nil
    var isRefreshing: Bool = false

    @State private var selectedID: String?

    private var points: [Point] {
        LocalCostPresentation.chartEntries(summary: summary)
            .map { entry in
                Point(id: entry.id, date: entry.date, costUSD: entry.costUSD, totalTokens: entry.totalTokens, costIsComplete: entry.costIsComplete)
            }
    }

    private var selectedPoint: Point? {
        guard let selectedID else { return nil }
        return points.first(where: { $0.id == selectedID })
    }

    private var statusText: String? {
        LocalCostPresentation.statusText(summary: summary, refreshError: refreshError, isRefreshing: isRefreshing)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricRow(title: "Today", cost: summary.todayCostUSD, tokens: summary.todayTokens, isComplete: summary.todayCostIsComplete)
            metricRow(title: "Last 30 Days", cost: summary.last30DaysCostUSD, tokens: summary.last30DaysTokens, isComplete: summary.last30DaysCostIsComplete)
            metricRow(title: "All-Time", cost: summary.lifetimeCostUSD, tokens: summary.lifetimeTokens, isComplete: summary.lifetimeCostIsComplete)

            if let statusText {
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundStyle(refreshError == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
                    .frame(height: 14, alignment: .leading)
            }

            Divider()

            if points.isEmpty {
                Text(summary.updatedAt == nil ? "用量统计完成后显示历史。" : "No cost history data.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                MiniBarChart(points: points, selectedID: $selectedID)

                HStack {
                    if let first = points.first {
                        Text(shortDay(first.date))
                    }

                    Spacer()

                    if let last = points.last {
                        Text(shortDay(last.date))
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 0) {
                    Text(primaryDetailText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 16, alignment: .leading)
                    Text(secondaryDetailText())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: 16, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(
            width: Self.panelWidth,
            height: Self.panelHeight(hasHistory: !points.isEmpty, hasStatus: statusText != nil),
            alignment: .topLeading
        )
        .help(LocalCostPresentation.explanation(summary: summary, refreshError: refreshError))
    }

    private func metricRow(title: String, cost: Double, tokens: Int, isComplete: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Text("\(summary.updatedAt == nil ? "—" : compactTokens(tokens)) tokens")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(LocalCostPresentation.costText(cost: cost, isComplete: isComplete, hasResult: summary.updatedAt != nil, currency: currency))
                .font(.system(size: 12, weight: .semibold))
        }
    }

    private func primaryDetailText() -> String {
        if let point = selectedPoint {
            let cost = LocalCostPresentation.costText(cost: point.costUSD, isComplete: point.costIsComplete, hasResult: true, currency: currency)
            return "\(shortDay(point.date)) · \(cost)"
        }
        return "Last 30 days trend"
    }

    private func secondaryDetailText() -> String {
        if let point = selectedPoint {
            return "\(compactTokens(point.totalTokens)) tokens"
        }
        return "Hover bars for daily details"
    }
}
