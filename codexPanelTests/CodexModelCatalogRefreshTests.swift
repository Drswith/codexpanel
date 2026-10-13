import Foundation
import XCTest

@MainActor
final class CodexModelCatalogRefreshTests: CodexPanelTestCase {
    func testRefreshPersistsPerAccountAndPreservesConfigurationOnFailure() async throws {
        try self.writeOAuthConfig()
        let initial = try CodexModelCatalog.parse(Data(#"{"models":[{"slug":"old","service_tiers":[{"id":"priority"}]}]}"#.utf8))
        let fetched = CodexModelCatalog(models: [.init(slug: "future", displayName: "Future", reasoningEfforts: ["low", "deep"], defaultReasoningEffort: "low", hasServiceTierMetadata: false)], fetchedAt: Date())
        let service = CatalogFetcherSpy(result: .success(fetched))
        let sync = CatalogSyncSpy()
        let store = TokenStore(syncService: sync, loadServiceTierCatalog: { initial }, codexModelCatalogService: service)
        let before = store.config.global
        let syncCallsBeforeRefresh = sync.calls
        await store.refreshCodexModelCatalog()
        XCTAssertEqual(service.requests.count, 1)
        XCTAssertEqual(service.requests.first?.accountID, "remote-a")
        XCTAssertEqual(store.codexServiceTierCatalog?.models.map(\.slug), ["future"])
        XCTAssertEqual(store.config.global.defaultModel, before.defaultModel)
        XCTAssertEqual(store.config.global.reasoningEffort, before.reasoningEffort)
        XCTAssertEqual(store.config.global.serviceTier, before.serviceTier)
        XCTAssertEqual(sync.calls, syncCallsBeforeRefresh)
        XCTAssertEqual(CodexModelCatalogSnapshotStore().load(accountID: "a")?.models.map(\.slug), ["future"])
        await store.refreshCodexModelCatalog()
        XCTAssertEqual(service.requests.count, 1, "自动刷新应节流")
        service.result = .failure(URLError(.notConnectedToInternet))
        await store.refreshCodexModelCatalog(force: true)
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(store.codexServiceTierCatalog?.models.map(\.slug), ["future"])
        XCTAssertNotNil(store.codexModelRefreshError)
        XCTAssertFalse(store.isRefreshingCodexModels)
        XCTAssertEqual(sync.calls, syncCallsBeforeRefresh)
        // 重新启动读取最近成功目录；不能被较旧的原生缓存覆盖。
        let reopened = TokenStore(syncService: sync, loadServiceTierCatalog: { initial }, codexModelCatalogService: service)
        XCTAssertEqual(reopened.codexServiceTierCatalog?.models.map(\.slug), ["future"])
    }

    func testAccountSwitchDiscardsLateResponseAndDoesNotReuseOtherAccountCatalog() async throws {
        try self.writeOAuthConfig()
        let service = CatalogFetcherSpy(result: .success(CodexModelCatalog(models: [.init(slug: "a-model")], fetchedAt: Date())))
        service.suspend = true
        let store = TokenStore(syncService: CatalogSyncSpy(), loadServiceTierCatalog: { nil }, codexModelCatalogService: service)
        let first = Task { await store.refreshCodexModelCatalog(force: true) }
        for _ in 0..<100 where service.continuation == nil { await Task.yield() }
        XCTAssertNotNil(service.continuation)
        await store.refreshCodexModelCatalog(force: true)
        XCTAssertEqual(service.requests.count, 1, "同一账号的在途刷新应合并")
        var config = store.config
        config.active.accountId = "b"
        config.providers[0].activeAccountId = "b"
        try CodexPanelConfigStore().save(config)
        store.load()
        XCTAssertNil(store.codexServiceTierCatalog)
        service.continuation?.resume(returning: try service.result.get())
        service.continuation = nil
        await first.value
        XCTAssertNil(store.codexServiceTierCatalog, "旧账号响应不能覆盖新账号")
        XCTAssertNil(CodexModelCatalogSnapshotStore().load(accountID: "b"))
        service.suspend = false
        service.result = .success(CodexModelCatalog(models: [.init(slug: "b-model")], fetchedAt: Date()))
        await store.refreshCodexModelCatalog()
        XCTAssertEqual(service.requests.last?.accountID, "remote-b")
        XCTAssertEqual(store.codexServiceTierCatalog?.models.map(\.slug), ["b-model"])
    }

    func testChangingModelUsesReturnedCapabilitiesAndSyncReceivesSameCatalog() async throws {
        try self.writeOAuthConfig()
        let catalog = CodexModelCatalog(models: [
            .init(slug: "future", reasoningEfforts: ["none", "deep"], defaultReasoningEffort: "none", serviceTiers: []),
        ], fetchedAt: Date())
        let sync = CatalogSyncSpy()
        let store = TokenStore(syncService: sync, loadServiceTierCatalog: { catalog }, codexModelCatalogService: CatalogFetcherSpy(result: .success(catalog)))
        XCTAssertEqual(store.serviceTierOptions(for: "future", currentValue: "ultrafast"), ["standard", "ultrafast"])
        try store.updateRouteModel("future")
        XCTAssertEqual(store.config.global.reasoningEffort, "none")
        XCTAssertEqual(store.config.global.serviceTier, "standard")
        XCTAssertEqual(sync.catalog, catalog)
        XCTAssertThrowsError(try store.updateReasoningEffort("ultra"))
        try store.updateReasoningEffort("deep")
        XCTAssertEqual(store.config.global.reasoningEffort, "deep")
    }

    func testNativeCacheUpdatesOnlyWhenAccountIdentityMatches() async throws {
        try self.writeOAuthConfig()
        var native = CodexModelCatalog(models: [.init(slug: "old")], fetchedAt: Date(), identity: "account-a")
        let service = CatalogFetcherSpy(result: .success(native))
        let store = TokenStore(syncService: CatalogSyncSpy(), loadServiceTierCatalog: { native }, codexModelCatalogService: service)
        await store.refreshCodexModelCatalog(force: true)
        native = CodexModelCatalog(models: [.init(slug: "new")], fetchedAt: Date().addingTimeInterval(1), identity: "account-a")
        store.reloadCodexServiceTierCatalog()
        XCTAssertEqual(store.codexServiceTierCatalog?.models.map(\.slug), ["new"])
        native = CodexModelCatalog(models: [.init(slug: "other-account")], fetchedAt: Date().addingTimeInterval(2), identity: "account-b")
        store.reloadCodexServiceTierCatalog()
        XCTAssertEqual(store.codexServiceTierCatalog?.models.map(\.slug), ["new"])
        XCTAssertEqual(store.codexServiceTierCatalog?.identity, "account-a")
    }

    func testBundledExecutableSupportsMergedDesktopLayout() throws {
        let app = CodexPaths.realHome.appendingPathComponent("ChatGPT.app")
        let executable = app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        XCTAssertEqual(CodexModelCatalogService.bundledExecutable(in: app), executable)
    }

    func testRPCHandshakePaginationFreshCacheAndCleanup() async throws {
        let report = CodexPaths.realHome.appendingPathComponent("rpc-report.json")
        let script = try self.makeServerScript("""
        import json, os, sys
        home = os.environ['CODEX_HOME']
        assert not os.path.exists(os.path.join(home, 'auth.json'))
        assert not os.path.exists(os.path.join(home, 'config.toml'))
        assert 'OPENAI_API_KEY' not in os.environ
        methods = []
        for line in sys.stdin:
            m = json.loads(line); method = m['method']; methods.append(method)
            if method == 'initialized': continue
            if method == 'initialize':
                assert m['params']['capabilities']['experimentalApi']
                result = {}
            elif method == 'account/login/start':
                assert m['params']['type'] == 'chatgptAuthTokens'
                assert m['params']['chatgptAccountId'] == 'remote-a'
                result = {'type': 'chatgptAuthTokens'}
            elif method == 'model/list':
                assert m['params']['includeHidden']
                if 'cursor' not in m['params']:
                    result = {'data': [{'model':'future', 'displayName':'Future', 'supportedReasoningEfforts':[{'reasoningEffort':'deep'}]}], 'nextCursor':'next'}
                else:
                    assert m['params']['cursor'] == 'next'
                    result = {'data': [{'model':'hidden', 'hidden':True}], 'nextCursor':None}
                    with open(os.path.join(home, 'models_cache.json'), 'w') as f:
                        json.dump({'models':[{'slug':'future','service_tiers':[{'id':'priority'}]}]}, f)
                    with open(\(self.pythonString(report.path)), 'w') as f:
                        json.dump({'home':home,'methods':methods}, f)
            else: raise Exception('unexpected operation')
            print(json.dumps({'method':'account/updated','params':{}}), flush=True)
            print(json.dumps({'id':m['id'],'result':result}), flush=True)
        """)
        let service = CodexModelCatalogService(timeout: 10, executableResolver: { _ in script })
        let catalog = try await service.fetchCatalog(self.request)
        XCTAssertEqual(catalog.models.map(\.slug), ["future", "hidden"])
        XCTAssertEqual(catalog.reasoningEffortOptions(for: "future"), ["deep"])
        XCTAssertEqual(catalog.serviceTierOptions(for: "future"), ["standard", "fast"])
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertEqual(trace["methods"] as? [String], ["initialize", "initialized", "account/login/start", "model/list", "model/list"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(trace["home"] as? String)))
    }

    func testRPCDeadlineKillsChildAndRemovesTemporaryHome() async throws {
        let report = CodexPaths.realHome.appendingPathComponent("timeout-report.json")
        let script = try self.makeServerScript("""
        import json, os, time
        with open(\(self.pythonString(report.path)), 'w') as f:
            json.dump({'pid':os.getpid(),'home':os.environ['CODEX_HOME']}, f)
        time.sleep(20)
        """)
        let service = CodexModelCatalogService(timeout: 5, executableResolver: { _ in script })
        do { _ = try await service.fetchCatalog(self.request); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? CodexModelCatalogError, .timedOut) }
        let trace = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(trace["home"] as? String)))
        XCTAssertEqual(kill(pid_t(try XCTUnwrap(trace["pid"] as? Int)), 0), -1)
    }

    private var request: CodexModelCatalogRequest {
        .init(accessToken: "test-access", accountID: "remote-a", planType: "pro", preferredAppPath: nil)
    }
    private func makeServerScript(_ body: String) throws -> URL {
        let url = CodexPaths.realHome.appendingPathComponent("fake-codex-" + UUID().uuidString)
        try Data(("#!/usr/bin/python3\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
    private func pythonString(_ value: String) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), encoding: .utf8)!
    }
    private func writeOAuthConfig() throws {
        let accounts = try ["a", "b"].map { id in
            CodexPanelProviderAccount.fromTokenAccount(try self.makeOAuthAccount(accountID: "remote-" + id, email: id + "@example.com", localAccountID: id), existingID: id)
        }
        let provider = CodexPanelProvider(id: "openai-oauth", kind: .openAIOAuth, label: "OpenAI", activeAccountId: "a", accounts: accounts)
        try CodexPanelConfigStore().save(CodexPanelConfig(
            global: CodexPanelGlobalSettings(defaultModel: "custom", reviewModel: "custom", reasoningEffort: "ultra", serviceTier: "ultrafast"),
            active: CodexPanelActiveSelection(providerId: provider.id, accountId: "a"), providers: [provider]))
    }
}

@MainActor
private final class CatalogFetcherSpy: CodexModelCatalogFetching {
    var requests: [CodexModelCatalogRequest] = []
    var result: Result<CodexModelCatalog, Error>
    var suspend = false
    var continuation: CheckedContinuation<CodexModelCatalog, Error>?
    init(result: Result<CodexModelCatalog, Error>) { self.result = result }
    func fetchCatalog(_ request: CodexModelCatalogRequest) async throws -> CodexModelCatalog {
        self.requests.append(request)
        if self.suspend { return try await withCheckedThrowingContinuation { self.continuation = $0 } }
        return try self.result.get()
    }
}

@MainActor
private final class CatalogSyncSpy: CodexSynchronizing {
    var calls = 0
    var catalog: CodexModelCatalog?
    func synchronize(config: CodexPanelConfig) throws { self.calls += 1 }
    func synchronize(config: CodexPanelConfig, modelCatalog: CodexModelCatalog?) throws {
        self.calls += 1
        self.catalog = modelCatalog
    }
}
