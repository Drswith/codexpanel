import Foundation

final class TokscaleCostSummaryService: LocalCostSummaryProviding, @unchecked Sendable {
    static let cacheSource = "tokscale-v4"

    private let queue = DispatchQueue(label: "com.codexpanel.tokscale", qos: .utility)
    private let codexRootProvider: () -> URL
    private let stateRootProvider: () -> URL
    // 选择和 revision 始终由 engineLock 保护，主线程切换无需等待扫描队列。
    private nonisolated let engineLock = NSLock()
    private nonisolated(unsafe) var selectedEngine: TokscaleEngineDescriptor?
    private nonisolated(unsafe) var engineRevision: UInt64 = 0
    private let seedDataProvider: () throws -> Data
    private let processRunner: any TokscaleProcessRunning
    private let calendarProvider: () -> Calendar
    private let inheritedEnvironment: () -> [String: String]
    private let clock: () -> Date
    private let refreshPricing: Bool
    private let scanTimeout: TimeInterval
    private var lastPricingRefresh: [String: Date] = [:]

    init(
        codexRootURL: URL? = nil,
        stateRootURL: URL? = nil,
        executableURL: URL? = nil,
        seedDataProvider: @escaping () throws -> Data = {
            guard let url = Bundle.main.url(forResource: "tokscale-pricing-seed", withExtension: "json")
                ?? Bundle.main.url(forResource: "tokscale-pricing-seed", withExtension: "json", subdirectory: "Resources") else {
                throw TokscaleError.pricingSeedMissing
            }
            return try Data(contentsOf: url)
        },
        processRunner: any TokscaleProcessRunning = TokscaleProcessRunner(),
        calendarProvider: @escaping () -> Calendar = { .current },
        inheritedEnvironment: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment },
        clock: @escaping () -> Date = Date.init,
        refreshPricing: Bool = true,
        scanTimeout: TimeInterval = 120
    ) {
        // 不能在初始化时读取大缓存或捕获真实 home；测试/开发 profile 可在运行前改变。
        self.codexRootProvider = { codexRootURL ?? CodexPaths.codexRoot }
        self.stateRootProvider = { stateRootURL ?? CodexPaths.codexBarRoot.appendingPathComponent("tokscale", isDirectory: true) }
        self.selectedEngine = executableURL.map { TokscaleEngineDescriptor(source: .installed, executableURL: $0, version: "4.20.0") }
        self.seedDataProvider = seedDataProvider
        self.processRunner = processRunner
        self.calendarProvider = calendarProvider
        self.inheritedEnvironment = inheritedEnvironment
        self.clock = clock
        self.refreshPricing = refreshPricing
        self.scanTimeout = scanTimeout
    }

    nonisolated func setEngine(_ engine: TokscaleEngineDescriptor?) {
        self.engineLock.withLock {
            self.selectedEngine = engine
            self.engineRevision &+= 1
        }
    }

    func load(
        now: Date = Date(),
        modelPricingOverrides: [String: CodexPanelModelPricing] = [:]
    ) throws -> LocalCostSummary {
        let selection = self.engineLock.withLock { (self.selectedEngine, self.engineRevision) }
        guard let engine = selection.0 else { throw TokscaleError.engineNotSelected }
        guard engine.isCompatible else { throw TokscaleError.incompatibleVersion(engine.version) }
        let shouldCancel = self.cancellationCheck(for: selection.1)
        let codexRoot = self.codexRootProvider()
        let stateRoot = self.stateRootProvider()
        let calendar = self.calendarProvider()
        let inherited = self.inheritedEnvironment()
        return try self.queue.sync {
            guard !shouldCancel() else { throw TokscaleError.cancelled }
            try self.prepareState(at: stateRoot, calendar: calendar, overrides: modelPricingOverrides)
            var environment = Self.environment(
                codexRoot: codexRoot, stateRoot: stateRoot,
                timeZone: calendar.timeZone, inherited: inherited, cacheOnly: true
            )
            if engine.source == .installed { environment["PATH"] = TokscaleEngineManager.executionPath(inherited: inherited) }
            let data = try self.processRunner.run(TokscaleProcessRequest(
                executableURL: engine.executableURL,
                arguments: ["graph", "--client", "codex", "--no-spinner"],
                environment: environment,
                workingDirectoryURL: stateRoot,
                timeout: self.scanTimeout,
                shouldCancel: shouldCancel
            ))
            guard !shouldCancel() else { throw TokscaleError.cancelled }
            let summary = try Self.decodeGraph(data, now: now, calendar: calendar)
            guard !shouldCancel() else { throw TokscaleError.cancelled }
            self.schedulePricingRefresh(engine: engine, revision: selection.1, codexRoot: codexRoot, stateRoot: stateRoot, calendar: calendar, inherited: inherited)
            return summary
        }
    }

    private func prepareState(
        at root: URL,
        calendar: Calendar,
        overrides: [String: CodexPanelModelPricing]
    ) throws {
        let manager = FileManager.default
        for component in ["", "home", "tmp", "cache"] {
            try manager.createDirectory(at: root.appendingPathComponent(component), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let settings: [String: Any] = [
            "defaultClients": ["codex"],
            "scanner": ["bucketTimezone": calendar.timeZone.identifier],
        ]
        try self.writeIfChanged(JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]), to: root.appendingPathComponent("settings.json"))
        let customURL = root.appendingPathComponent("custom-pricing.json")
        if overrides.isEmpty {
            if manager.fileExists(atPath: customURL.path) { try manager.removeItem(at: customURL) }
        } else {
            let models = overrides.mapValues { pricing in
                [
                    "input_cost_per_token": pricing.inputUSDPerToken,
                    "cache_read_input_token_cost": pricing.cachedInputUSDPerToken,
                    "output_cost_per_token": pricing.outputUSDPerToken,
                ]
            }
            try self.writeIfChanged(JSONSerialization.data(withJSONObject: ["models": models], options: [.sortedKeys]), to: customURL)
        }
        let cache = root.appendingPathComponent("cache/pricing-litellm.json")
        if !Self.hasDecodablePricingCache(at: cache) {
            try CodexPaths.writeSecureFile(self.seedDataProvider(), to: cache)
        }
    }

    private static func hasDecodablePricingCache(at url: URL) -> Bool {
        // v4.20.0 保存解码后的 ModelPricing（22 个 Option<f64>），不是含字符串元数据的原始 LiteLLM 响应。
        struct Cache: Decodable {
            let timestamp: UInt64
            let data: [String: [String: Double?]]
        }
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.timestamp <= UInt64(max(0, Date().timeIntervalSince1970)) else { return false }
        return true
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if (try? Data(contentsOf: url)) != data { try CodexPaths.writeSecureFile(data, to: url) }
    }

    private nonisolated func cancellationCheck(for revision: UInt64) -> @Sendable () -> Bool {
        { [weak self] in
            guard let self else { return true }
            return self.engineLock.withLock { self.engineRevision != revision }
        }
    }

    private func schedulePricingRefresh(engine: TokscaleEngineDescriptor, revision: UInt64, codexRoot: URL, stateRoot: URL, calendar: Calendar, inherited: [String: String]) {
        guard self.refreshPricing else { return }
        let shouldCancel = self.cancellationCheck(for: revision)
        // 与 graph 共用串行队列，永远只有一个 helper；联网更新不延迟本轮缓存结果。
        self.queue.async {
            guard !shouldCancel() else { return }
            let now = self.clock()
            guard self.lastPricingRefresh[stateRoot.path].map({ now.timeIntervalSince($0) >= 3_600 }) ?? true else { return }
            var environment = Self.environment(
                codexRoot: codexRoot, stateRoot: stateRoot,
                timeZone: calendar.timeZone, inherited: inherited, cacheOnly: false
            )
            if engine.source == .installed { environment["PATH"] = TokscaleEngineManager.executionPath(inherited: inherited) }
            guard !shouldCancel() else { return }
            let previousRefresh = self.lastPricingRefresh[stateRoot.path]
            self.lastPricingRefresh[stateRoot.path] = now
            do {
                _ = try self.processRunner.run(TokscaleProcessRequest(
                    executableURL: engine.executableURL,
                    arguments: ["pricing", "gpt-5.5", "--json", "--no-spinner"],
                    environment: environment,
                    workingDirectoryURL: stateRoot,
                    timeout: 15,
                    maximumOutputBytes: 1_024 * 1_024,
                    shouldCancel: shouldCancel
                ))
            } catch TokscaleError.cancelled {
                self.lastPricingRefresh[stateRoot.path] = previousRefresh
            } catch {
                // 网络失败仍节流；显式取消不占用下一次启用的更新时间。
            }
        }
    }

    nonisolated static func environment(codexRoot: URL, stateRoot: URL, timeZone: TimeZone, inherited: [String: String], cacheOnly: Bool) -> [String: String] {
        var environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": stateRoot.appendingPathComponent("home").path,
            "TMPDIR": stateRoot.appendingPathComponent("tmp").path,
            "CODEX_HOME": codexRoot.path,
            "OPENCODEX_HOME": stateRoot.appendingPathComponent("home/.opencodex").path,
            "TOKSCALE_CONFIG_DIR": stateRoot.path,
            "TOKSCALE_RECOVERY_DISABLE": "1",
            "TZ": timeZone.identifier,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TERM": "dumb",
            "NO_COLOR": "1",
        ]
        if cacheOnly { environment["TOKSCALE_PRICING_CACHE_ONLY"] = "1" }
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy"] {
            environment[key] = inherited[key]
        }
        return environment
    }

    static func decodeGraph(_ data: Data, now: Date, calendar: Calendar) throws -> LocalCostSummary {
        let report: Graph
        do { report = try JSONDecoder().decode(Graph.self, from: data) }
        catch { throw TokscaleError.invalidReport }
        guard TokscaleVersion.isCompatible(report.meta.version) else { throw TokscaleError.incompatibleVersion(report.meta.version) }
        guard report.summary.totalTokens >= 0,
              report.summary.totalCost.isFinite, report.summary.totalCost >= 0 else { throw TokscaleError.invalidReport }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        let today = calendar.startOfDay(for: now)
        let last30 = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        var seen: Set<String> = []
        var entries: [DailyCostEntry] = []
        var graphTokens = 0
        var graphCost = 0.0
        for contribution in report.contributions {
            guard contribution.date.count == 10,
                  let date = formatter.date(from: contribution.date), formatter.string(from: date) == contribution.date,
                  seen.insert(contribution.date).inserted,
                  contribution.totals.tokens >= 0,
                  contribution.totals.cost.isFinite, contribution.totals.cost >= 0 else { throw TokscaleError.invalidReport }
            let added = graphTokens.addingReportingOverflow(contribution.totals.tokens)
            guard !added.overflow else { throw TokscaleError.invalidReport }
            graphTokens = added.partialValue
            graphCost += contribution.totals.cost
            guard graphCost.isFinite else { throw TokscaleError.invalidReport }
            guard date <= today else { continue }
            let clients = contribution.clients ?? []
            let completeProvenance: Bool
            if contribution.totals.tokens == 0 && contribution.totals.cost == 0 {
                // 空用量没有待估算金额；仍保留上游显式的不完整标记。
                completeProvenance = clients.allSatisfy { $0.costIsComplete != false }
            } else if clients.isEmpty {
                completeProvenance = contribution.totals.costProvenance?.isKnown == true
            } else {
                // mixed 不携带未知金额占比；细分到 client/model 后仍混合时保守提示。
                completeProvenance = clients.allSatisfy { $0.costIsComplete != false && $0.costProvenance?.isKnown == true }
                    && contribution.totals.costProvenance?.kind != "unknown"
            }
            let complete = contribution.totals.costIsComplete != false && completeProvenance
            entries.append(DailyCostEntry(id: contribution.date, date: date, costUSD: contribution.totals.cost, totalTokens: contribution.totals.tokens, costIsComplete: complete))
        }
        guard graphTokens == report.summary.totalTokens,
              abs(graphCost - report.summary.totalCost) <= max(1e-8, abs(graphCost) * 1e-9) else { throw TokscaleError.invalidReport }
        entries.sort { $0.date > $1.date }
        var summary = LocalCostSummary.empty
        summary.dailyEntries = entries
        summary.updatedAt = now
        summary.source = Self.cacheSource
        summary.bucketTimeZoneIdentifier = calendar.timeZone.identifier
        summary.historicalModels = Array(Set(report.summary.models.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })).sorted()
        for entry in entries {
            summary.lifetimeTokens += entry.totalTokens
            summary.lifetimeCostUSD += entry.costUSD
            summary.lifetimeCostIsComplete = summary.lifetimeCostIsComplete && entry.costIsComplete
            if entry.date >= last30 {
                summary.last30DaysTokens += entry.totalTokens
                summary.last30DaysCostUSD += entry.costUSD
                summary.last30DaysCostIsComplete = summary.last30DaysCostIsComplete && entry.costIsComplete
            }
            if entry.date == today {
                summary.todayTokens += entry.totalTokens
                summary.todayCostUSD += entry.costUSD
                summary.todayCostIsComplete = summary.todayCostIsComplete && entry.costIsComplete
            }
        }
        return summary
    }

    private struct Graph: Decodable {
        struct Meta: Decodable { let version: String }
        struct Summary: Decodable { let totalTokens: Int; let totalCost: Double; let models: [String] }
        struct Contribution: Decodable {
            struct Totals: Decodable {
                let tokens: Int
                let cost: Double
                let costIsComplete: Bool?
                let costProvenance: Provenance?
            }
            struct Client: Decodable { let costIsComplete: Bool?; let costProvenance: Provenance? }
            let date: String
            let totals: Totals
            let clients: [Client]?
        }
        struct Provenance: Decodable {
            let kind: String
            var isKnown: Bool { kind == "estimated" || kind == "providerReported" }
        }
        let meta: Meta
        let summary: Summary
        let contributions: [Contribution]
    }
}
