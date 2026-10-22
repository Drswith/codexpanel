import Foundation
import XCTest

@MainActor
final class LocalCostSummaryPresentationTests: XCTestCase {
    func testLegacyCacheDecodesWithoutNewCoverageAndSourceFields() throws {
        let data = Data(#"""
        {
          "todayCostUSD": 1.5, "todayTokens": 1200,
          "last30DaysCostUSD": 3, "last30DaysTokens": 2400,
          "lifetimeCostUSD": 5, "lifetimeTokens": 4000,
          "dailyEntries": [{"id":"2026-10-22", "date":"2026-10-21T16:00:00Z", "costUSD":1.5, "totalTokens":1200}],
          "updatedAt":"2026-10-22T04:00:00Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let summary = try decoder.decode(LocalCostSummary.self, from: data)

        XCTAssertEqual(summary.todayTokens, 1200)
        XCTAssertTrue(summary.todayCostIsComplete)
        XCTAssertTrue(summary.last30DaysCostIsComplete)
        XCTAssertTrue(summary.lifetimeCostIsComplete)
        XCTAssertTrue(try XCTUnwrap(summary.dailyEntries.first).costIsComplete)
        XCTAssertNil(summary.source)
        XCTAssertNil(summary.bucketTimeZoneIdentifier)
        XCTAssertNil(summary.historicalModels)
        XCTAssertEqual(
            LocalCostPresentation.statusText(summary: summary, refreshError: nil, isRefreshing: false),
            "旧版缓存，等待重新统计"
        )
    }

    func testCoverageAndSourceSurviveCacheRoundTrip() throws {
        var summary = self.summary()
        summary.todayCostIsComplete = false
        summary.last30DaysCostIsComplete = false
        summary.lifetimeCostIsComplete = false
        summary.historicalModels = ["gpt-5.5", "unknown-model"]
        summary.dailyEntries = [DailyCostEntry(
            id: "2026-10-22", date: try self.date("2026-10-21T16:00:00Z"),
            costUSD: 0.25, totalTokens: 5000, costIsComplete: false
        )]
        let decoded = try JSONDecoder().decode(LocalCostSummary.self, from: JSONEncoder().encode(summary))

        XCTAssertFalse(decoded.todayCostIsComplete)
        XCTAssertFalse(decoded.last30DaysCostIsComplete)
        XCTAssertFalse(decoded.lifetimeCostIsComplete)
        XCTAssertFalse(try XCTUnwrap(decoded.dailyEntries.first).costIsComplete)
        XCTAssertEqual(decoded.source, "tokscale-v4")
        XCTAssertEqual(decoded.bucketTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(decoded.historicalModels, ["gpt-5.5", "unknown-model"])
    }

    func testFirstFailureShowsUnavailableInsteadOfSuccessfulZero() {
        let empty = LocalCostSummary.empty
        XCTAssertEqual(
            LocalCostPresentation.statusText(summary: empty, refreshError: "统计程序超时", isRefreshing: false),
            "用量暂不可用"
        )
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: 0, isComplete: true, hasResult: false, currency: self.currency),
            "—"
        )
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: 0, isComplete: true, hasResult: true, currency: self.currency),
            "$0.00"
        )
    }

    func testUnknownPriceNeverLooksLikeFreeUsage() {
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: 0, isComplete: false, hasResult: true, currency: self.currency),
            "价格未知"
        )
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: 2.5, isComplete: false, hasResult: true, currency: self.currency),
            "≥$2.50"
        )
        var summary = self.summary()
        summary.lifetimeCostIsComplete = false
        XCTAssertEqual(
            LocalCostPresentation.statusText(summary: summary, refreshError: nil, isRefreshing: false),
            "部分用量缺少价格"
        )
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: summary.todayCostUSD, isComplete: summary.todayCostIsComplete, hasResult: true, currency: self.currency),
            "$1.50"
        )
    }

    func testRefreshFailureKeepsKnownResultAndExplainsItsAge() {
        let summary = self.summary()
        XCTAssertEqual(
            LocalCostPresentation.statusText(summary: summary, refreshError: "统计程序超时", isRefreshing: false),
            "更新失败，显示上次结果"
        )
        XCTAssertEqual(
            LocalCostPresentation.costText(cost: summary.todayCostUSD, isComplete: true, hasResult: true, currency: self.currency),
            "$1.50"
        )
        let explanation = LocalCostPresentation.explanation(summary: summary, refreshError: "统计程序超时")
        XCTAssertTrue(explanation.contains("统计程序超时"))
        XCTAssertTrue(explanation.contains("按请求开始时间"))
        XCTAssertTrue(explanation.contains("Asia/Shanghai"))
    }

    func testTrendUsesThirtyCalendarDaysInSummaryTimeZone() throws {
        var summary = self.summary()
        summary.updatedAt = try self.date("2026-10-22T04:00:00Z")
        summary.dailyEntries = try [
            ("too-old", "2026-09-21T16:00:00Z"),
            ("first-day", "2026-09-22T16:00:00Z"),
            ("today", "2026-10-21T16:00:00Z"),
            ("future", "2026-10-22T16:00:00Z"),
        ].map { id, timestamp in
            DailyCostEntry(id: id, date: try self.date(timestamp), costUSD: 1, totalTokens: 100)
        }
        XCTAssertEqual(LocalCostPresentation.chartEntries(summary: summary).map(\.id), ["first-day", "today"])
    }

    private func summary() -> LocalCostSummary {
        LocalCostSummary(
            todayCostUSD: 1.5, todayTokens: 1200,
            last30DaysCostUSD: 3, last30DaysTokens: 2400,
            lifetimeCostUSD: 5, lifetimeTokens: 4000,
            dailyEntries: [], updatedAt: Date(timeIntervalSince1970: 1_792_641_600),
            source: "tokscale-v4", bucketTimeZoneIdentifier: "Asia/Shanghai"
        )
    }

    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    private func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}
