import Foundation
import XCTest

@MainActor
final class TokscaleCostSummaryServiceTests: CodexPanelTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func graph(_ days: [(String, Int, Double, String)], models: [String] = ["gpt-5.5"]) throws -> Data {
        let rows: [[String: Any]] = days.map { day, tokens, cost, provenance in
            ["date": day, "totals": ["tokens": tokens, "cost": cost, "costProvenance": ["kind": provenance]]]
        }
        return try JSONSerialization.data(withJSONObject: [
            "meta": ["version": "4.20.0"],
            "summary": ["totalTokens": days.reduce(0) { $0 + $1.1 }, "totalCost": days.reduce(0) { $0 + $1.2 }, "models": models],
            "contributions": rows,
        ])
    }

    func testDailyBucketsUseOfficialDatesAndThirtyDayInclusiveWindow() throws {
        let data = try self.graph([
            ("2026-09-22", 10, 0.1, "unknown"),
            ("2026-09-23", 20, 0.2, "estimated"),
            ("2026-10-21", 30, 0.3, "estimated"),
            ("2026-10-22", 40, 0.4, "estimated"),
            ("2026-10-23", 500, 5, "estimated"),
        ], models: ["gpt-5.5", "gpt-5.4", "gpt-5.5"])
        let summary = try TokscaleCostSummaryService.decodeGraph(data, now: self.date("2026-10-22T12:00:00Z"), calendar: self.utcCalendar)
        XCTAssertEqual(summary.todayTokens, 40)
        XCTAssertEqual(summary.last30DaysTokens, 90)
        XCTAssertEqual(summary.lifetimeTokens, 100)
        XCTAssertEqual(summary.lifetimeCostUSD, 1, accuracy: 1e-12)
        XCTAssertTrue(summary.todayCostIsComplete)
        XCTAssertTrue(summary.last30DaysCostIsComplete)
        XCTAssertFalse(summary.lifetimeCostIsComplete)
        XCTAssertEqual(summary.dailyEntries.map(\.id), ["2026-10-22", "2026-10-21", "2026-09-23", "2026-09-22"])
        XCTAssertEqual(summary.historicalModels, ["gpt-5.4", "gpt-5.5"])
        XCTAssertEqual(summary.source, "tokscale-v4")
    }

    func testShanghaiMidnightPreservesUpstreamRequestStartBucket() throws {
        var calendar = self.utcCalendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let summary = try TokscaleCostSummaryService.decodeGraph(
            self.graph([("2026-10-21", 2_400, 0.0184, "estimated")]),
            now: self.date("2026-10-21T16:01:00Z"), calendar: calendar
        )
        XCTAssertEqual(summary.todayTokens, 0)
        XCTAssertEqual(summary.last30DaysTokens, 2_400)
        XCTAssertEqual(summary.bucketTimeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(summary.dailyEntries.first?.date, self.date("2026-10-20T16:00:00Z"))
    }

    func testUnknownAndMixedProvenanceNeverLookLikeCompleteZeroCosts() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.graph([("2026-10-22", 100, 0, "mixed")])) as? [String: Any])
        var rows = try XCTUnwrap(object["contributions"] as? [[String: Any]])
        rows[0]["clients"] = [
            ["costProvenance": ["kind": "estimated"]],
            ["costProvenance": ["kind": "unknown"]],
        ]
        object["contributions"] = rows
        let summary = try TokscaleCostSummaryService.decodeGraph(JSONSerialization.data(withJSONObject: object), now: self.date("2026-10-22T12:00:00Z"), calendar: self.utcCalendar)
        XCTAssertEqual(summary.todayTokens, 100)
        XCTAssertFalse(summary.todayCostIsComplete)
        XCTAssertFalse(summary.last30DaysCostIsComplete)
        XCTAssertFalse(summary.lifetimeCostIsComplete)
        XCTAssertEqual(summary.dailyEntries.first?.costIsComplete, false)
    }

    func testMissingProvenanceAndExplicitIncompleteFlagRemainIncomplete() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: self.graph([("2026-10-22", 100, 0.2, "estimated")])) as? [String: Any])
        object["contributions"] = [["date": "2026-10-22", "totals": ["tokens": 100, "cost": 0.2, "costIsComplete": false]]]
        let result = try TokscaleCostSummaryService.decodeGraph(JSONSerialization.data(withJSONObject: object), now: self.date("2026-10-22T12:00:00Z"), calendar: self.utcCalendar)
        XCTAssertFalse(result.todayCostIsComplete)
    }

    func testEmptyUsageIsCompleteUnlessTotalsOrClientExplicitlyMarkIncomplete() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: self.graph([("2026-10-22", 0, 0, "unknown")])) as? [String: Any])
        for (totalsIncomplete, clientIncomplete, expectedComplete) in [
            (false, false, true), (true, false, false), (false, true, false), (true, true, false),
        ] {
            var object = base
            var totals: [String: Any] = ["tokens": 0, "cost": 0, "costProvenance": ["kind": "unknown"]]
            if totalsIncomplete { totals["costIsComplete"] = false }
            var client: [String: Any] = ["costProvenance": ["kind": "unknown"]]
            if clientIncomplete { client["costIsComplete"] = false }
            object["contributions"] = [["date": "2026-10-22", "totals": totals, "clients": [client]]]
            let result = try TokscaleCostSummaryService.decodeGraph(JSONSerialization.data(withJSONObject: object), now: self.date("2026-10-22T12:00:00Z"), calendar: self.utcCalendar)
            XCTAssertEqual(result.todayCostIsComplete, expectedComplete)
            XCTAssertEqual(result.last30DaysCostIsComplete, expectedComplete)
            XCTAssertEqual(result.lifetimeCostIsComplete, expectedComplete)
            XCTAssertEqual(result.dailyEntries.first?.costIsComplete, expectedComplete)
        }
    }

    func testInvalidDatesNegativeValuesAndMismatchedTotalsAreRejected() throws {
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: self.graph([("2026-10-22", 100, 1, "estimated")])) as? [String: Any])
        var badTotals = valid
        badTotals["summary"] = ["totalTokens": 101, "totalCost": 1, "models": ["gpt-5.5"]]
        for data in [
            try self.graph([("2026-02-30", 100, 1, "estimated")]),
            try self.graph([("2026-10-22", -1, 1, "estimated")]),
            try self.graph([("2026-10-22", 100, -1, "estimated")]),
            try self.graph([("2026-10-22", 100, 1, "estimated"), ("2026-10-22", 100, 1, "estimated")]),
            try JSONSerialization.data(withJSONObject: badTotals),
            Data("not JSON".utf8),
        ] {
            XCTAssertThrowsError(try TokscaleCostSummaryService.decodeGraph(data, now: Date(), calendar: self.utcCalendar)) { error in
                XCTAssertEqual(error as? TokscaleError, .invalidReport)
            }
        }
    }

    func testGraphVersionAcceptsCompatibleFourSeriesAndRejectsOtherVersions() throws {
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: self.graph([])) as? [String: Any])
        for version in ["4.20.1", "4.21.0", "4.19.9", "5.0.0"] {
            var object = base
            object["meta"] = ["version": version]
            let data = try JSONSerialization.data(withJSONObject: object)
            if TokscaleVersion.isCompatible(version) {
                XCTAssertNoThrow(try TokscaleCostSummaryService.decodeGraph(data, now: Date(), calendar: self.utcCalendar))
            } else {
                XCTAssertThrowsError(try TokscaleCostSummaryService.decodeGraph(data, now: Date(), calendar: self.utcCalendar)) { error in
                    XCTAssertEqual(error as? TokscaleError, .incompatibleVersion(version))
                }
            }
        }
    }

    func testDefaultServiceRequiresEngineBeforeReadingOrScanning() throws {
        let runner = RecordingTokscaleRunner(data: try self.graph([]))
        let service = TokscaleCostSummaryService(seedDataProvider: { XCTFail("关闭时不得读取价格或历史"); return Data() }, processRunner: runner)
        XCTAssertThrowsError(try service.load()) { error in XCTAssertEqual(error as? TokscaleError, .engineNotSelected) }
        XCTAssertTrue(runner.requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.codexBarRoot.appendingPathComponent("tokscale").path))
        service.setEngine(TokscaleEngineDescriptor(source: .installed, executableURL: URL(fileURLWithPath: "/usr/bin/true"), version: "5.0.0"))
        XCTAssertThrowsError(try service.load()) { error in XCTAssertEqual(error as? TokscaleError, .incompatibleVersion("5.0.0")) }
    }

    func testDisableAndReenableSameEngineCancelsOldScanWithoutWaiting() throws {
        let scanStarted = self.expectation(description: "旧扫描已启动")
        let completed = self.expectation(description: "旧扫描已取消")
        let runner = BlockingGraphTokscaleRunner(data: try self.graph([]), started: scanStarted)
        let service = TokscaleCostSummaryService(executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { Data(#"{"timestamp":0,"data":{}}"#.utf8) }, processRunner: runner)
        DispatchQueue.global(qos: .utility).async {
            do {
                _ = try service.load()
                XCTFail("旧扫描应被取消")
            } catch {
                XCTAssertEqual(error as? TokscaleError, .cancelled)
            }
            completed.fulfill()
        }
        self.wait(for: [scanStarted], timeout: 2)
        let started = Date()
        service.setEngine(nil)
        service.setEngine(TokscaleEngineDescriptor(source: .installed, executableURL: URL(fileURLWithPath: "/usr/bin/true"), version: "4.20.0"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        runner.release.signal()
        self.wait(for: [completed], timeout: 2)
        XCTAssertEqual(runner.commands, ["graph"])
        service.setEngine(nil)
        XCTAssertThrowsError(try service.load()) { error in XCTAssertEqual(error as? TokscaleError, .engineNotSelected) }
    }

    func testSkippedPricingDoesNotThrottleReenabledEngineForAnHour() throws {
        let skipped = self.expectation(description: "旧价格更新已取消")
        let updated = self.expectation(description: "重新启用后更新价格")
        let runner = RecordingTokscaleRunner(data: try self.graph([]), pricingCompleted: updated)
        let clock = TokscaleActionClock()
        let engine = TokscaleEngineDescriptor(source: .installed, executableURL: URL(fileURLWithPath: "/usr/bin/true"), version: "4.20.0")
        let service = TokscaleCostSummaryService(executableURL: engine.executableURL, seedDataProvider: { Data(#"{"timestamp":0,"data":{}}"#.utf8) }, processRunner: runner, clock: { clock.read() })
        clock.onFirstRead = { [weak service] in
            service?.setEngine(nil)
            service?.setEngine(engine)
            skipped.fulfill()
        }
        _ = try service.load()
        self.wait(for: [skipped], timeout: 2)
        _ = try service.load()
        self.wait(for: [updated], timeout: 2)
        XCTAssertEqual(runner.requests.map { $0.arguments[0] }, ["graph", "graph", "pricing"])
    }

    func testEnvironmentDoesNotInheritCredentialsOtherClientsOrScanOverrides() {
        let state = CodexPaths.codexBarRoot.appendingPathComponent("tokscale")
        let env = TokscaleCostSummaryService.environment(codexRoot: CodexPaths.codexRoot, stateRoot: state, timeZone: self.utcCalendar.timeZone, inherited: [
            "HOME": "/real-home", "CODEX_HOME": "/real-codex", "TOKSCALE_EXTRA_DIRS": "/real-history",
            "TOKSCALE_CONFIG_DIR": "/real-tokscale", "TOKSCALE_PRICING_CACHE_ONLY": "1",
            "OPENAI_API_KEY": "do-not-forward", "HTTP_PROXY": "http://127.0.0.1:12345", "NO_PROXY": "localhost",
        ], cacheOnly: false)
        XCTAssertEqual(env["CODEX_HOME"], CodexPaths.codexRoot.path)
        XCTAssertEqual(env["HOME"], state.appendingPathComponent("home").path)
        XCTAssertEqual(env["TOKSCALE_CONFIG_DIR"], state.path)
        XCTAssertEqual(env["TOKSCALE_RECOVERY_DISABLE"], "1")
        XCTAssertNil(env["TOKSCALE_EXTRA_DIRS"])
        XCTAssertNil(env["TOKSCALE_PRICING_CACHE_ONLY"])
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertEqual(env["NO_PROXY"], "localhost")
        XCTAssertEqual(env["HTTP_PROXY"], "http://127.0.0.1:12345")
    }

    func testOverridesAreReplacedAndRemovedWithoutOverwritingPriceCache() throws {
        let state = CodexPaths.codexBarRoot.appendingPathComponent("tokscale")
        let runner = RecordingTokscaleRunner(data: try self.graph([]))
        let seed = Data(#"{"timestamp":0,"data":{"gpt-5.5":{"input_cost_per_token":0.000005}}}"#.utf8)
        let service = TokscaleCostSummaryService(stateRootURL: state, executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { seed }, processRunner: runner, refreshPricing: false)
        _ = try service.load(modelPricingOverrides: ["gpt-5.5": CodexPanelModelPricing(inputUSDPerToken: 1e-6, cachedInputUSDPerToken: 2e-7, outputUSDPerToken: 3e-6)])
        let customURL = state.appendingPathComponent("custom-pricing.json")
        let custom = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: customURL)) as? [String: [String: [String: Double]]])
        XCTAssertEqual(custom["models"]?["gpt-5.5"]?["input_cost_per_token"], 1e-6)
        let cached = Data(#"{"timestamp":0,"data":{"updated-model":{"input_cost_per_token":0.000009}}}"#.utf8)
        let cacheURL = state.appendingPathComponent("cache/pricing-litellm.json")
        try cached.write(to: cacheURL)
        _ = try service.load(modelPricingOverrides: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: customURL.path))
        XCTAssertEqual(try Data(contentsOf: cacheURL), cached)
        XCTAssertEqual(runner.requests.map(\.arguments), Array(repeating: ["graph", "--client", "codex", "--no-spinner"], count: 2))
        XCTAssertTrue(runner.requests.allSatisfy { $0.environment["TOKSCALE_PRICING_CACHE_ONLY"] == "1" })
    }

    func testCorruptPriceCacheIsRepairedBeforeOfflineScan() throws {
        let state = CodexPaths.codexBarRoot.appendingPathComponent("tokscale")
        let cache = state.appendingPathComponent("cache/pricing-litellm.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: cache)
        let seed = Data(#"{"timestamp":0,"data":{}}"#.utf8)
        let service = TokscaleCostSummaryService(stateRootURL: state, executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { seed }, processRunner: RecordingTokscaleRunner(data: try self.graph([])), refreshPricing: false)
        _ = try service.load()
        XCTAssertEqual(try Data(contentsOf: cache), seed)
    }

    func testOfficialNormalizedPriceCacheWithNullRatesIsPreserved() throws {
        let state = CodexPaths.codexBarRoot.appendingPathComponent("tokscale")
        let cache = state.appendingPathComponent("cache/pricing-litellm.json")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let saved = Data(#"{"timestamp":0,"data":{"gpt-5.5":{"input_cost_per_token":0.000005,"output_cost_per_token":0.00003,"cache_read_input_token_cost":null,"input_cost_per_token_above_272k_tokens":null}}}"#.utf8)
        try saved.write(to: cache)
        let service = TokscaleCostSummaryService(stateRootURL: state, executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: {
            XCTFail("官方已规范化且含 null 的缓存不应被种子替换")
            return Data()
        }, processRunner: RecordingTokscaleRunner(data: try self.graph([])), refreshPricing: false)
        _ = try service.load()
        XCTAssertEqual(try Data(contentsOf: cache), saved)
    }

    func testPricingTimeoutPreservesSeedAndNextOfflineGraph() throws {
        let state = CodexPaths.codexBarRoot.appendingPathComponent("tokscale")
        let seed = Data(#"{"timestamp":0,"data":{"gpt-5.5":{"input_cost_per_token":0.000005}}}"#.utf8)
        let runner = RecordingTokscaleRunner(data: try self.graph([("2026-10-22", 100, 0.1, "estimated")]), pricingFailure: .timedOut)
        let service = TokscaleCostSummaryService(stateRootURL: state, executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { seed }, processRunner: runner)
        let first = try service.load()
        let second = try service.load()
        XCTAssertEqual(first.lifetimeTokens, second.lifetimeTokens)
        XCTAssertEqual(second.lifetimeCostUSD, 0.1)
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("cache/pricing-litellm.json")), seed)
        XCTAssertEqual(runner.requests.map { $0.arguments[0] }, ["graph", "pricing", "graph"])
    }

    func testModelsAreReturnedWithSummaryWithoutAnAdditionalScan() throws {
        let runner = RecordingTokscaleRunner(data: try self.graph([("2026-10-22", 1, 0.1, "estimated")]))
        let service = TokscaleCostSummaryService(executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { Data(#"{"timestamp":0,"data":{}}"#.utf8) }, processRunner: runner, refreshPricing: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.codexBarRoot.appendingPathComponent("tokscale").path))
        XCTAssertEqual(runner.requests.count, 0)
        let summary = try service.load()
        XCTAssertEqual(summary.historicalModels, ["gpt-5.5"])
        XCTAssertEqual(runner.requests.count, 1)
    }

    func testPricingRefreshIsSerializedThrottledAndNeverMakesGraphOnline() throws {
        let checked = self.expectation(description: "首次更新与节流检查完成")
        checked.expectedFulfillmentCount = 2
        let updated = self.expectation(description: "两次价格更新完成")
        updated.expectedFulfillmentCount = 2
        let runner = RecordingTokscaleRunner(data: try self.graph([]), pricingCompleted: updated)
        let initialTime = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = TokscaleTestClock(initialTime)
        let service = TokscaleCostSummaryService(executableURL: URL(fileURLWithPath: "/usr/bin/true"), seedDataProvider: { Data(#"{"timestamp":0,"data":{}}"#.utf8) }, processRunner: runner, clock: {
            let now = clock.now
            if now == initialTime { checked.fulfill() }
            return now
        }, refreshPricing: true)
        _ = try service.load()
        _ = try service.load()
        self.wait(for: [checked], timeout: 2)
        clock.now.addTimeInterval(3_601)
        _ = try service.load()
        self.wait(for: [updated], timeout: 2)
        XCTAssertEqual(runner.requests.map { $0.arguments[0] }, ["graph", "pricing", "graph", "graph", "pricing"])
        XCTAssertTrue(runner.requests.filter { $0.arguments[0] == "graph" }.allSatisfy { $0.environment["TOKSCALE_PRICING_CACHE_ONLY"] == "1" })
        XCTAssertTrue(runner.requests.filter { $0.arguments[0] == "pricing" }.allSatisfy { $0.environment["TOKSCALE_PRICING_CACHE_ONLY"] == nil && $0.timeout == 15 })
        XCTAssertEqual(runner.maximumConcurrentRuns, 1)
    }

    func testSelectedHelperReadsCompressedSyntheticCodexHistoryOffline() throws {
        guard let helperPath = ProcessInfo.processInfo.environment["CODEXPANEL_TEST_TOKSCALE_PATH"],
              FileManager.default.isExecutableFile(atPath: helperPath) else {
            throw XCTSkip("通过 CODEXPANEL_TEST_TOKSCALE_PATH 指定隔离测试使用的官方 tokscale")
        }
        let executable = URL(fileURLWithPath: helperPath)
        let session = #"{"type":"session_meta","payload":{"id":"bench-session","timestamp":"2026-10-22T15:59:58Z","source":"cli"}}"# + "\n"
            + #"{"type":"turn_context","timestamp":"2026-10-22T15:59:59Z","payload":{"model":"gpt-5.5"}}"# + "\n"
            + #"{"type":"event_msg","timestamp":"2026-10-22T16:00:01Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":200,"reasoning_output_tokens":50,"total_tokens":1200}}}}"# + "\n"
        let payload = Data(session.utf8)
        // 标准 Zstandard 单段 raw block：测试格式支持，不依赖第三方压缩工具。
        var zstd = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        let size = UInt32(payload.count)
        zstd.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        let header = size << 3 | 1
        zstd.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: header >> ($0 * 8)) })
        zstd.append(payload)
        let path = CodexPaths.codexRoot.appendingPathComponent("sessions/rollout-bench-session.jsonl.zst")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try zstd.write(to: path)
        let seed = Data(#"{"timestamp":0,"data":{"gpt-5.5":{"input_cost_per_token":0.000005,"cache_read_input_token_cost":0.0000005,"output_cost_per_token":0.00003}}}"#.utf8)
        var calendar = self.utcCalendar
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let service = TokscaleCostSummaryService(executableURL: executable, seedDataProvider: { seed }, calendarProvider: { calendar }, refreshPricing: false)
        let now = self.date("2026-10-22T16:01:00Z")
        let summary = try service.load(now: now)
        XCTAssertEqual(summary.lifetimeTokens, 1_200)
        XCTAssertEqual(summary.lifetimeCostUSD, 0.0092, accuracy: 1e-12)
        XCTAssertTrue(summary.lifetimeCostIsComplete)
        XCTAssertEqual(summary.todayTokens, 0)
        XCTAssertEqual(summary.dailyEntries.first?.id, "2026-10-22")
        let overridden = try service.load(now: now, modelPricingOverrides: [
            "gpt-5.5": CodexPanelModelPricing(inputUSDPerToken: 10e-6, cachedInputUSDPerToken: 1e-6, outputUSDPerToken: 40e-6),
        ])
        XCTAssertEqual(overridden.lifetimeTokens, 1_200)
        XCTAssertEqual(overridden.lifetimeCostUSD, 0.0144, accuracy: 1e-12)
        let restored = try service.load(now: now)
        XCTAssertEqual(restored.lifetimeCostUSD, 0.0092, accuracy: 1e-12)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.authURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.configTomlURL.path))
    }
}

private final class BlockingGraphTokscaleRunner: TokscaleProcessRunning, @unchecked Sendable {
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recorded: [String] = []
    var commands: [String] { self.lock.withLock { self.recorded } }
    let data: Data
    init(data: Data, started: XCTestExpectation) {
        self.data = data
        self.started = started
    }
    func run(_ request: TokscaleProcessRequest) throws -> Data {
        self.lock.withLock { self.recorded.append(request.arguments[0]) }
        if request.arguments[0] == "graph" {
            self.started.fulfill()
            _ = self.release.wait(timeout: .now() + 5)
        }
        guard !request.shouldCancel() else { throw TokscaleError.cancelled }
        return self.data
    }
}

private final class TokscaleActionClock: @unchecked Sendable {
    var onFirstRead: (() -> Void)?
    func read() -> Date {
        let action = self.onFirstRead
        self.onFirstRead = nil
        action?()
        return Date(timeIntervalSince1970: 1_700_000_000)
    }
}

private final class TokscaleTestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class RecordingTokscaleRunner: TokscaleProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TokscaleProcessRequest] = []
    private var running = 0
    private var maximum = 0
    let data: Data
    let pricingFailure: TokscaleError?
    let pricingCompleted: XCTestExpectation?
    init(data: Data, pricingFailure: TokscaleError? = nil, pricingCompleted: XCTestExpectation? = nil) {
        self.data = data
        self.pricingFailure = pricingFailure
        self.pricingCompleted = pricingCompleted
    }
    var requests: [TokscaleProcessRequest] { self.lock.withLock { self.recorded } }
    var maximumConcurrentRuns: Int { self.lock.withLock { self.maximum } }
    func run(_ request: TokscaleProcessRequest) throws -> Data {
        self.lock.withLock {
            self.running += 1
            self.maximum = max(self.maximum, self.running)
            self.recorded.append(request)
        }
        defer {
            self.lock.withLock { self.running -= 1 }
            if request.arguments.first == "pricing" { self.pricingCompleted?.fulfill() }
        }
        if request.arguments.first == "pricing", let pricingFailure { throw pricingFailure }
        return request.arguments.first == "pricing" ? Data("{}".utf8) : self.data
    }
}
