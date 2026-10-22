import Foundation
import XCTest

@MainActor
final class TokenStoreLocalUsageTests: CodexPanelTestCase {
    func testLegacyConfigStartsDisabledWithoutDiscoveringInstallingOrScanning() throws {
        let data = try JSONEncoder().encode(CodexPanelConfig())
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "localUsage")
        try CodexPaths.writeSecureFile(try JSONSerialization.data(withJSONObject: legacy), to: CodexPaths.barConfigURL)
        let installed = self.installed
        let manager = LocalUsageEngineManagerStub(discover: { [installed] })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)

        store.refreshLocalCostSummary(force: true, minimumInterval: 0)
        store.installManagedTokscaleEngine()
        store.load()
        self.drainMainRunLoop()

        XCTAssertFalse(store.localUsageEnabled)
        XCTAssertEqual(store.config.localUsage.preferredSource, .installed)
        XCTAssertNil(store.config.localUsage.installedExecutablePath)
        XCTAssertFalse(store.hasCheckedTokscaleEngines)
        XCTAssertEqual(manager.discoveryCount, 0)
        XCTAssertEqual(manager.installationCount, 0)
        XCTAssertEqual(service.loadCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CodexPaths.costCacheURL.path))
    }

    func testEnablingDiscoversBeforeScanningAndPrefersInstalledEngine() throws {
        let installed = self.installed
        let managed = self.managed
        let manager = LocalUsageEngineManagerStub(discover: { [managed, installed] })
        let service = LocalUsageSummaryStub {
            var summary = Self.summary(tokens: 7)
            summary.historicalModels = ["graph-model"]
            return summary
        }
        let store = self.makeStore(manager: manager, service: service)
        XCTAssertEqual(service.loadCount, 0)

        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }

        XCTAssertEqual(manager.discoveryCount, 1)
        XCTAssertEqual(manager.installationCount, 0)
        XCTAssertEqual(store.activeTokscaleEngine, installed)
        XCTAssertEqual(service.loadedEngines, [installed])
        XCTAssertEqual(store.historicalModels, ["graph-model"])
        XCTAssertTrue(try CodexPanelConfigStore().load().localUsage.enabled)
    }

    func testDisabledUsageReadsModelsFromCachedSummaryAndCurrentCustomPrices() throws {
        var cached = Self.summary(tokens: 7)
        cached.historicalModels = [" cached-model ", "cached-model", ""]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try CodexPaths.writeSecureFile(try encoder.encode(cached), to: CodexPaths.costCacheURL)
        let configStore = CodexPanelConfigStore()
        var config = CodexPanelConfig(modelPricing: ["custom-model": .zero])
        try configStore.save(config)
        let manager = LocalUsageEngineManagerStub(discover: { [] })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)

        XCTAssertEqual(store.historicalModels, ["cached-model", "custom-model"])
        config.modelPricing = ["new-custom-model": .zero]
        try configStore.save(config)
        store.load()

        XCTAssertEqual(store.historicalModels, ["cached-model", "new-custom-model"])
        XCTAssertFalse(store.localUsageEnabled)
        XCTAssertEqual(manager.discoveryCount, 0)
        XCTAssertEqual(service.loadCount, 0)
    }

    func testDisablingWhileDiscoveryRunsPreventsScanWhenDiscoveryCompletes() {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let installed = self.installed
        let manager = LocalUsageEngineManagerStub(discover: {
            _ = gate.wait(timeout: .now() + 5)
            return [installed]
        })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { manager.discoveryCount == 1 }

        store.setLocalUsageEnabled(false)
        gate.signal()
        self.waitUntil { !store.isCheckingTokscaleEngines }

        XCTAssertFalse(store.localUsageEnabled)
        XCTAssertTrue(store.hasCheckedTokscaleEngines)
        XCTAssertEqual(store.tokscaleEngines, [installed])
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertNil(service.selectedEngine)
        XCTAssertEqual(service.loadCount, 0)
        XCTAssertEqual(manager.installationCount, 0)
    }

    func testExplicitManagedInstallPersistsSelectionAndUsesItAtNextStartup() throws {
        let installed = self.installed
        let managed = self.managed
        let manager = LocalUsageEngineManagerStub(discover: { [installed] }, install: { managed })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }

        store.installManagedTokscaleEngine()
        self.waitUntil { !store.isInstallingTokscaleEngine && !store.isRefreshingLocalCostSummary && service.loadCount == 2 }

        XCTAssertEqual(manager.installationCount, 1)
        XCTAssertEqual(store.activeTokscaleEngine, managed)
        let saved = try CodexPanelConfigStore().load().localUsage
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(saved.preferredSource, .managed)
        XCTAssertNil(saved.installedExecutablePath)

        let reopenedManager = LocalUsageEngineManagerStub(discover: { [installed, managed] })
        let reopenedService = LocalUsageSummaryStub()
        let reopened = self.makeStore(manager: reopenedManager, service: reopenedService)
        self.waitUntil { !reopened.isCheckingTokscaleEngines && !reopened.isRefreshingLocalCostSummary && reopenedService.loadCount == 1 }
        XCTAssertEqual(reopened.activeTokscaleEngine, managed)
        XCTAssertEqual(reopenedService.loadedEngines, [managed])
        XCTAssertEqual(reopenedManager.installationCount, 0)
    }

    func testFailedDownloadPreservesInstalledEngineAndPreference() throws {
        let installed = self.installed
        let manager = LocalUsageEngineManagerStub(discover: { [installed] })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }

        store.installManagedTokscaleEngine()
        self.waitUntil { !store.isInstallingTokscaleEngine }

        XCTAssertEqual(store.tokscaleEngineError, "测试下载失败")
        XCTAssertEqual(store.activeTokscaleEngine, installed)
        XCTAssertEqual(service.selectedEngine, installed)
        XCTAssertEqual(service.loadCount, 1)
        XCTAssertEqual(store.tokscaleEngines, [installed])
        XCTAssertEqual(try CodexPanelConfigStore().load().localUsage.preferredSource, .installed)
    }

    func testDisablingWhileInstallRunsRetainsCopyWithoutReenablingOrSelectingIt() throws {
        let installed = self.installed
        let managed = self.managed
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let manager = LocalUsageEngineManagerStub(discover: { [installed] }, install: {
            _ = gate.wait(timeout: .now() + 5)
            return managed
        })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }
        store.installManagedTokscaleEngine()
        self.waitUntil { manager.installationCount == 1 }

        store.setLocalUsageEnabled(false)
        gate.signal()
        self.waitUntil { !store.isInstallingTokscaleEngine }

        XCTAssertFalse(store.localUsageEnabled)
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertNil(service.selectedEngine)
        XCTAssertTrue(store.tokscaleEngines.contains(managed))
        XCTAssertEqual(service.loadCount, 1)
        let saved = try CodexPanelConfigStore().load().localUsage
        XCTAssertFalse(saved.enabled)
        XCTAssertEqual(saved.preferredSource, .installed)
    }

    func testReenablingDuringSuccessfulInstallRediscoversAndResumesPreferredInstalledEngine() throws {
        let installed = self.installed
        let managed = self.managed
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let manager = LocalUsageEngineManagerStub(discover: { [installed] }, install: {
            _ = gate.wait(timeout: .now() + 5)
            return managed
        })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }
        store.installManagedTokscaleEngine()
        self.waitUntil { manager.installationCount == 1 }

        store.setLocalUsageEnabled(false)
        store.setLocalUsageEnabled(true)
        XCTAssertTrue(store.localUsageEnabled)
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertEqual(manager.discoveryCount, 1)
        gate.signal()
        self.waitUntil {
            !store.isInstallingTokscaleEngine && !store.isCheckingTokscaleEngines &&
                !store.isRefreshingLocalCostSummary && service.loadCount == 2
        }

        XCTAssertEqual(manager.discoveryCount, 2)
        XCTAssertEqual(manager.installationCount, 1)
        XCTAssertTrue(store.tokscaleEngines.contains(managed))
        XCTAssertEqual(store.activeTokscaleEngine, installed)
        XCTAssertEqual(service.loadedEngines, [installed, installed])
        XCTAssertNil(store.tokscaleEngineError)
        let saved = try CodexPanelConfigStore().load().localUsage
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(saved.preferredSource, .installed)
    }

    func testReenablingDuringFailedInstallResumesInstalledEngineAndRetainsDownloadError() throws {
        let installed = self.installed
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let manager = LocalUsageEngineManagerStub(discover: { [installed] }, install: {
            _ = gate.wait(timeout: .now() + 5)
            throw LocalUsageTestError.downloadFailed
        })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }
        store.installManagedTokscaleEngine()
        self.waitUntil { manager.installationCount == 1 }

        store.setLocalUsageEnabled(false)
        store.setLocalUsageEnabled(true)
        XCTAssertTrue(store.localUsageEnabled)
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertEqual(manager.discoveryCount, 1)
        gate.signal()
        self.waitUntil {
            !store.isInstallingTokscaleEngine && !store.isCheckingTokscaleEngines &&
                !store.isRefreshingLocalCostSummary && service.loadCount == 2
        }

        XCTAssertEqual(manager.discoveryCount, 2)
        XCTAssertEqual(manager.installationCount, 1)
        XCTAssertEqual(store.activeTokscaleEngine, installed)
        XCTAssertEqual(service.loadedEngines, [installed, installed])
        XCTAssertEqual(store.tokscaleEngineError, "测试下载失败")
        let saved = try CodexPanelConfigStore().load().localUsage
        XCTAssertTrue(saved.enabled)
        XCTAssertEqual(saved.preferredSource, .installed)
    }

    func testDisablingWhileScanRunsDiscardsResultAndPreservesPreviousCache() throws {
        let cached = Self.summary(tokens: 42)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let cachedData = try encoder.encode(cached)
        try CodexPaths.writeSecureFile(cachedData, to: CodexPaths.costCacheURL)
        let installed = self.installed
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let result = Self.summary(tokens: 84)
        let manager = LocalUsageEngineManagerStub(discover: { [installed] })
        let service = LocalUsageSummaryStub {
            _ = gate.wait(timeout: .now() + 5)
            return result
        }
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { service.loadCount == 1 }
        XCTAssertTrue(store.isRefreshingLocalCostSummary)

        store.setLocalUsageEnabled(false)
        gate.signal()
        self.waitUntil { !store.isRefreshingLocalCostSummary }

        XCTAssertEqual(store.localCostSummary.lifetimeTokens, 42)
        XCTAssertEqual(try Data(contentsOf: CodexPaths.costCacheURL), cachedData)
        XCTAssertNil(store.localCostRefreshError)
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertEqual(service.loadCount, 1)
        XCTAssertFalse(try CodexPanelConfigStore().load().localUsage.enabled)
    }

    func testManualVersionCheckWhileDisabledDoesNotEnableOrScan() {
        let installed = self.installed
        let manager = LocalUsageEngineManagerStub(discover: { [installed] })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)

        store.checkTokscaleEngines()
        self.waitUntil { !store.isCheckingTokscaleEngines }

        XCTAssertFalse(store.localUsageEnabled)
        XCTAssertTrue(store.hasCheckedTokscaleEngines)
        XCTAssertEqual(store.tokscaleEngines, [installed])
        XCTAssertNil(store.activeTokscaleEngine)
        XCTAssertEqual(service.loadCount, 0)
        XCTAssertEqual(manager.installationCount, 0)
    }

    func testExplicitInstalledPathPersistsAndWinsAtNextStartup() throws {
        let installed = self.installed
        let alternate = TokscaleEngineDescriptor(
            source: .installed,
            executableURL: CodexPaths.codexBarRoot.appendingPathComponent("fixture/alternate/tokscale"),
            version: "4.21.0"
        )
        let manager = LocalUsageEngineManagerStub(discover: { [installed, alternate] })
        let service = LocalUsageSummaryStub()
        let store = self.makeStore(manager: manager, service: service)
        store.setLocalUsageEnabled(true)
        self.waitUntil { !store.isCheckingTokscaleEngines && !store.isRefreshingLocalCostSummary && service.loadCount == 1 }

        store.selectTokscaleEngine(id: alternate.id)
        self.waitUntil { !store.isRefreshingLocalCostSummary && service.loadCount == 2 }
        XCTAssertEqual(store.activeTokscaleEngine, alternate)
        XCTAssertEqual(try CodexPanelConfigStore().load().localUsage.installedExecutablePath, alternate.executableURL.path)

        let reopenedService = LocalUsageSummaryStub()
        let reopened = self.makeStore(manager: manager, service: reopenedService)
        self.waitUntil { !reopened.isCheckingTokscaleEngines && !reopened.isRefreshingLocalCostSummary && reopenedService.loadCount == 1 }
        XCTAssertEqual(reopened.activeTokscaleEngine, alternate)
        XCTAssertEqual(reopenedService.loadedEngines, [alternate])
        XCTAssertEqual(manager.installationCount, 0)
    }

    private var installed: TokscaleEngineDescriptor {
        TokscaleEngineDescriptor(source: .installed, executableURL: CodexPaths.codexBarRoot.appendingPathComponent("fixture/installed/tokscale"), version: "4.20.0")
    }

    private var managed: TokscaleEngineDescriptor {
        TokscaleEngineDescriptor(source: .managed, executableURL: CodexPaths.codexBarRoot.appendingPathComponent("engines/tokscale/4.20.0/tokscale"), version: "4.20.0")
    }

    private func makeStore(manager: LocalUsageEngineManagerStub, service: LocalUsageSummaryStub) -> TokenStore {
        TokenStore(
            syncService: LocalUsageSyncNoOp(),
            costSummaryService: service,
            tokscaleEngineManager: manager,
            openAIAccountGatewayService: LocalUsageGatewayNoOp(),
            openRouterGatewayService: LocalUsageGatewayNoOp(),
            chatCompletionsGatewayService: LocalUsageGatewayNoOp(),
            openRouterGatewayLeaseStore: LocalUsageLeaseNoOp(),
            aggregateGatewayLeaseStore: LocalUsageLeaseNoOp(),
            aggregateRouteJournalStore: LocalUsageLeaseNoOp(),
            codexRunningProcessIDs: { [] }
        )
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "等待本地引擎异步状态超时", file: file, line: line)
    }

    private func drainMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private static func summary(tokens: Int) -> LocalCostSummary {
        LocalCostSummary(
            todayCostUSD: 1, todayTokens: tokens, last30DaysCostUSD: 1, last30DaysTokens: tokens,
            lifetimeCostUSD: 1, lifetimeTokens: tokens, dailyEntries: [], updatedAt: Date(),
            source: "tokscale-v4", bucketTimeZoneIdentifier: TimeZone.current.identifier
        )
    }
}

private enum LocalUsageTestError: LocalizedError {
    case downloadFailed
    case noSelectedEngine
    var errorDescription: String? {
        switch self {
        case .downloadFailed: return "测试下载失败"
        case .noSelectedEngine: return "测试统计缺少已选引擎"
        }
    }
}

nonisolated final class LocalUsageEngineManagerStub: TokscaleEngineManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var discoveries = 0
    private var installations = 0
    private var installedManagedCopy: TokscaleEngineDescriptor?
    private let discovery: () throws -> [TokscaleEngineDescriptor]
    private let installation: () throws -> TokscaleEngineDescriptor

    init(discover: @escaping () throws -> [TokscaleEngineDescriptor], install: @escaping () throws -> TokscaleEngineDescriptor = { throw LocalUsageTestError.downloadFailed }) {
        self.discovery = discover
        self.installation = install
    }

    var discoveryCount: Int { self.lock.withLock { self.discoveries } }
    var installationCount: Int { self.lock.withLock { self.installations } }

    func discover() throws -> [TokscaleEngineDescriptor] {
        self.lock.withLock { self.discoveries += 1 }
        var engines = try self.discovery()
        if let managed = self.lock.withLock({ self.installedManagedCopy }), !engines.contains(where: { $0.id == managed.id }) {
            engines.append(managed)
        }
        return engines
    }

    func installManaged() throws -> TokscaleEngineDescriptor {
        self.lock.withLock { self.installations += 1 }
        let engine = try self.installation()
        self.lock.withLock { self.installedManagedCopy = engine }
        return engine
    }
}

private final class LocalUsageSummaryStub: LocalCostSummaryProviding {
    private let lock = NSLock()
    private var engine: TokscaleEngineDescriptor?
    private var engines: [TokscaleEngineDescriptor] = []
    private var calls = 0
    private let result: () throws -> LocalCostSummary

    init(result: @escaping () throws -> LocalCostSummary = {
        LocalCostSummary(
            todayCostUSD: 0, todayTokens: 0, last30DaysCostUSD: 0, last30DaysTokens: 0,
            lifetimeCostUSD: 0, lifetimeTokens: 0, dailyEntries: [], updatedAt: Date(),
            source: "tokscale-v4", bucketTimeZoneIdentifier: TimeZone.current.identifier
        )
    }) {
        self.result = result
    }

    var selectedEngine: TokscaleEngineDescriptor? { self.lock.withLock { self.engine } }
    var loadedEngines: [TokscaleEngineDescriptor] { self.lock.withLock { self.engines } }
    var loadCount: Int { self.lock.withLock { self.calls } }

    func setEngine(_ engine: TokscaleEngineDescriptor?) {
        self.lock.withLock { self.engine = engine }
    }

    func load(now: Date, modelPricingOverrides: [String: CodexPanelModelPricing]) throws -> LocalCostSummary {
        try self.lock.withLock {
            self.calls += 1
            guard let engine = self.engine else { throw LocalUsageTestError.noSelectedEngine }
            self.engines.append(engine)
        }
        return try self.result()
    }

}

private final class LocalUsageSyncNoOp: CodexSynchronizing {
    func synchronize(config: CodexPanelConfig) throws {}
}

private final class LocalUsageGatewayNoOp: OpenAIAccountGatewayControlling, OpenRouterGatewayControlling, ChatCompletionsGatewayControlling {
    func startIfNeeded() {}
    func stop() {}
    func updateState(accounts: [TokenAccount], quotaSortSettings: CodexPanelOpenAISettings.QuotaSortSettings, accountUsageMode: CodexPanelOpenAIAccountUsageMode, defaultProxy: OpenAIAccountGatewayConfiguredProxy?, proxyByAccountID: [String: OpenAIAccountGatewayConfiguredProxy]) {}
    func updateState(provider: CodexPanelProvider?, isActiveProvider: Bool) {}
    func currentRoutedAccountID() -> String? { nil }
    func stickyBindingsSnapshot() -> [OpenAIAggregateStickyBindingSnapshot] { [] }
    func clearStickyBinding(threadID: String) -> Bool { false }
}

private final class LocalUsageLeaseNoOp: OpenRouterGatewayLeaseStoring, OpenAIAggregateGatewayLeaseStoring, OpenAIAggregateRouteJournalStoring {
    func loadLease() -> OpenRouterGatewayLeaseSnapshot? { nil }
    func saveLease(_ lease: OpenRouterGatewayLeaseSnapshot) {}
    func loadProcessIDs() -> Set<pid_t> { [] }
    func saveProcessIDs(_ processIDs: Set<pid_t>) {}
    func clear() {}
    func hasActiveLease() -> Bool { false }
    func recordRoute(threadID: String, accountID: String, timestamp: Date) {}
    func routeHistory() -> [OpenAIAggregateRouteRecord] { [] }
}
