# CodexBar v1.2.7 选择性同步 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 将成本摘要非强制刷新修复和安全的聚合网关显式代理路由同步到 Codex Panel v1.5.9。

**Architecture:** 代理解析和 URLSession 选择保持在既有 OpenAI 聚合网关中；默认地址保存在 OpenAI 设置，账号覆盖复用导入数据中的 interopProxyKey。TokenStore 只负责把持久化配置转换为网关 state，HTTP 与 WebSocket 共享相同的账号代理选择器。

**Tech Stack:** Swift、SwiftUI、Foundation URLSession、Network framework、XCTest、Xcode。

## Global Constraints

- 不使用普通 Git merge；codexbar 与本仓库无共同基线。
- 只接受无认证 http、https、socks、socks5 代理；host 必须非空，端口必须在 1...65535。
- 显式代理优先级：账号 interopProxyKey profile、默认代理、既有 loopback-safe 系统代理。
- 不改 cached-token 口径、model_context_window、默认模型/service tier、Requesty 或上游发布物。
- Debug 测试使用隔离 home，不读取或修改真实 ~/.codex。

---

### Task 1: 聚合网关代理解析与会话选择

**Files:**
- Modify: codexPanel/Services/OpenAIAccountGatewayService.swift:12-25, 286-350, 410-655, 1060-1450
- Modify: codexPanel/Services/TokenStore.swift:952-960
- Test: codexPanelTests/OpenAIAccountGatewayServiceTests.swift
- Modify: codexPanelTests/TokenStoreGatewayLifecycleTests.swift:698-735
- Modify: codexPanelTests/TokenStoreSettingsTests.swift:749-765
- Modify: codexPanelTests/WhamServiceTests.swift:195-215
- Modify: codexPanelTests/OpenAIOAuthRefreshServiceTests.swift:95-115

**Interfaces:**
- Produces: OpenAIAccountGatewayConfiguredProxy、profilesByKey(fromInteropProxiesJSON:)、updateState(... defaultProxy:proxyByAccountID:)。
- Produces: 一个按配置缓存的显式代理 URLSession，供 HTTP 和 WebSocket 的共同 upstreamSession(for:) 使用。

- [ ] **Step 1: 写失败的 parser、profile 和优先级测试**

~~~swift
func testConfiguredProxyAcceptsAnonymousHTTPAndSOCKS() throws {
    XCTAssertEqual(
        try XCTUnwrap(OpenAIAccountGatewayConfiguredProxy(address: "http://127.0.0.1:7890")).address,
        "http://127.0.0.1:7890"
    )
    XCTAssertEqual(
        try XCTUnwrap(OpenAIAccountGatewayConfiguredProxy(address: "socks5://[::1]:7891")).address,
        "socks5://[::1]:7891"
    )
}

func testConfiguredProxyRejectsCredentialsAndOutOfRangePort() {
    XCTAssertNil(OpenAIAccountGatewayConfiguredProxy(address: "http://user:secret@127.0.0.1:7890"))
    XCTAssertNil(OpenAIAccountGatewayConfiguredProxy(address: "http://127.0.0.1:65536"))
}

func testAccountProxyOverridesDefaultAndUsesSameSessionForHTTPAndWebSocket() {
    let account = self.makeGatewayAccount(
        email: "proxy@example.com",
        accountId: "acct-proxy",
        openAIAccountId: "remote-proxy",
        accessToken: "access-proxy",
        refreshToken: "refresh-proxy",
        idToken: "id-proxy",
        planType: "plus"
    )
    let service = self.makeService()
    service.updateState(
        accounts: [account],
        quotaSortSettings: .init(),
        accountUsageMode: .aggregateGateway,
        defaultProxy: OpenAIAccountGatewayConfiguredProxy(address: "http://127.0.0.1:7890"),
        proxyByAccountID: [
            account.accountId: try! XCTUnwrap(
                OpenAIAccountGatewayConfiguredProxy(address: "socks5://127.0.0.1:7891")
            ),
        ]
    )

    XCTAssertEqual(service.configuredProxyForTesting(accountID: account.accountId)?.address, "socks5://127.0.0.1:7891")
    XCTAssertTrue(service.usesSameExplicitProxySessionForHTTPAndWebSocketForTesting(accountID: account.accountId))
}
~~~

- [ ] **Step 2: 运行测试，确认因类型、state 参数和测试观察 API 缺失而失败**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/OpenAIAccountGatewayServiceTests

Expected: 新测试编译失败，指出代理类型、扩展 updateState 参数或测试观察 API 不存在。

- [ ] **Step 3: 最小实现 parser、state 和会话缓存**

~~~swift
private func upstreamSession(for account: TokenAccount) -> URLSession {
    guard let proxy = self.configuredProxy(forAccountID: account.accountId) else { return self.urlSession }
    return self.explicitProxySession(for: proxy)
}

private func configuredProxy(forAccountID accountID: String) -> OpenAIAccountGatewayConfiguredProxy? {
    self.stateQueue.sync { self.proxyByAccountID[accountID] ?? self.defaultProxy }
}
~~~

Implement a Hashable proxy value that parses URL or imported profile records, rejects credentials and invalid ports, and produces connectionProxyDictionary. Extend the snapshot and state update, cache sessions by proxy, prune sessions no longer referenced by state, and route both bytes(for:) and webSocketTask(with:) through upstreamSession(for:). Keep the existing system-policy urlSession as fallback. Update TokenStore's protocol call with nil defaultProxy and an empty proxyByAccountID until Task 3 supplies the configured values. Update every OpenAIAccountGatewayControlling test double to match the expanded signature; the lifecycle spy retains the passed proxy values for Task 3 assertions.

- [ ] **Step 4: 运行测试，确认通过**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/OpenAIAccountGatewayServiceTests

Expected: OpenAIAccountGatewayServiceTests passes.

- [ ] **Step 5: 提交网关路由改动**

~~~bash
git add codexPanel/Services/OpenAIAccountGatewayService.swift codexPanel/Services/TokenStore.swift codexPanelTests/OpenAIAccountGatewayServiceTests.swift codexPanelTests/TokenStoreGatewayLifecycleTests.swift codexPanelTests/TokenStoreSettingsTests.swift codexPanelTests/WhamServiceTests.swift codexPanelTests/OpenAIOAuthRefreshServiceTests.swift
git commit -m "feat(网关): 支持按账号代理路由"
~~~

### Task 2: 默认代理配置与设置页

**Files:**
- Modify: codexPanel/Models/CodexPanelConfig.swift:231-360
- Modify: codexPanel/Services/TokenStore.swift:5-10
- Modify: codexPanel/Services/SettingsSaveRequestApplier.swift:15-28
- Modify: codexPanel/Views/Settings/SettingsWindowCoordinator.swift:17-55, 145-180, 340-430
- Modify: codexPanel/Views/Settings/SettingsWindowView.swift:281-320, 650-720
- Modify: codexPanel/Localization.swift:410-440
- Test: codexPanelTests/TokenStoreSettingsTests.swift
- Test: codexPanelTests/SettingsWindowCoordinatorTests.swift

**Interfaces:**
- Consumes: Task 1 的 OpenAIAccountGatewayConfiguredProxy(address:)。
- Produces: CodexPanelOpenAISettings.aggregateGatewayProxyURL: String? 和 normalizedAggregateGatewayProxyURL(_:)。
- Produces: OpenAIAccountSettingsUpdate.aggregateGatewayProxyURL，并通过 SettingsWindowDraft 和 SettingsSaveRequestApplier 完整持久化该值。

- [ ] **Step 1: 写失败的配置兼容与归一化测试**

~~~swift
func testAggregateGatewayProxyURLPersistsAndRejectsCredentials() throws {
    var config = CodexPanelConfig()
    config.openAI.aggregateGatewayProxyURL = "socks5://127.0.0.1:7890"

    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(CodexPanelConfig.self, from: data)

    XCTAssertEqual(decoded.openAI.aggregateGatewayProxyURL, "socks5://127.0.0.1:7890")
    XCTAssertNil(CodexPanelOpenAISettings.normalizedAggregateGatewayProxyURL("http://user:secret@127.0.0.1:7890"))
    XCTAssertNil(CodexPanelOpenAISettings.normalizedAggregateGatewayProxyURL("http://127.0.0.1:70000"))
}
~~~

- [ ] **Step 2: 运行测试，确认因缺少字段/归一化器而失败**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/TokenStoreSettingsTests

Expected: 新测试编译失败，指出 aggregateGatewayProxyURL 或归一化方法不存在。

- [ ] **Step 3: 最小实现配置和 UI**

~~~swift
var aggregateGatewayProxyURL: String?

static func normalizedAggregateGatewayProxyURL(_ value: String?) -> String? {
    guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          let proxy = OpenAIAccountGatewayConfiguredProxy(address: raw) else {
        return nil
    }
    return proxy.address
}
~~~

Add the coding key, initializer value, decoder fallback, an Accounts-page TextField, and localized title, hint, and input example that explicitly state HTTP(S)/SOCKS without authentication. Add aggregateGatewayProxyURL to OpenAIAccountSettingsUpdate with a nil default, SettingsWindowDraft, SettingsDirtyField and reconcile/makeSaveRequests. The applier must assign the normalized value to config.openAI so save triggers the existing persist -> publishState path.

- [ ] **Step 4: 运行测试，确认通过**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/TokenStoreSettingsTests

Expected: TokenStoreSettingsTests passes.

- [ ] **Step 5: 提交配置改动**

~~~bash
git add codexPanel/Models/CodexPanelConfig.swift codexPanel/Services/TokenStore.swift codexPanel/Services/SettingsSaveRequestApplier.swift codexPanel/Views/Settings/SettingsWindowCoordinator.swift codexPanel/Views/Settings/SettingsWindowView.swift codexPanel/Localization.swift codexPanelTests/TokenStoreSettingsTests.swift codexPanelTests/SettingsWindowCoordinatorTests.swift
git commit -m "feat(网关): 增加聚合代理配置"
~~~

### Task 3: TokenStore 接线与成本刷新回归

**Files:**
- Modify: codexPanel/Services/TokenStore.swift:935-970, 1193-1238
- Modify: codexPanelTests/TokenStoreGatewayLifecycleTests.swift
- Modify: codexPanelTests/TokenStoreSettingsTests.swift

**Interfaces:**
- Consumes: Task 1 的 profilesByKey(fromInteropProxiesJSON:) 与 Task 2 的默认代理设置。
- Produces: gateway 的默认代理/账号代理 state 和 TokenStore.shouldRefreshLocalCostSummary(updatedAt:force:minimumInterval:now:)。

- [ ] **Step 1: 写失败的 TokenStore 接线与刷新测试**

~~~swift
func testAggregateGatewayPublishesAccountProfileBeforeDefaultProxy() throws {
    let account = try self.makeOAuthAccount(accountID: "acct-proxy", email: "proxy@example.com")
    var stored = CodexPanelProviderAccount.fromTokenAccount(account)
    stored.interopProxyKey = "socks5|127.0.0.1|7891||"
    let provider = CodexPanelProvider(
        id: "openai-oauth",
        kind: .openAIOAuth,
        label: "OpenAI",
        activeAccountId: stored.id,
        accounts: [stored]
    )
    var config = CodexPanelConfig(
        active: .init(providerId: provider.id, accountId: stored.id),
        providers: [provider]
    )
    config.openAI.accountUsageMode = .aggregateGateway
    config.openAI.aggregateGatewayProxyURL = "http://127.0.0.1:7890"
    config.openAI.interopProxiesJSON = #"[{"proxy_key":"socks5|127.0.0.1|7891||","protocol":"socks5","host":"127.0.0.1","port":7891,"status":"active"}]"#
    try self.writeConfig(config)

    let gateway = OpenAIAccountGatewayControllerSpy()
    _ = TokenStore(
        openAIAccountGatewayService: gateway,
        aggregateGatewayLeaseStore: OpenAIAggregateGatewayLeaseStoreSpy(),
        codexRunningProcessIDs: { [] }
    )

    XCTAssertEqual(gateway.lastDefaultProxy?.address, "http://127.0.0.1:7890")
    XCTAssertEqual(gateway.lastProxyByAccountID["acct-proxy"]?.address, "socks5://127.0.0.1:7891")
}

func testLocalCostSummaryRefreshAllowsExpiredCacheAndBlocksFreshCache() {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
    XCTAssertTrue(TokenStore.shouldRefreshLocalCostSummary(
        updatedAt: now.addingTimeInterval(-301),
        force: false,
        minimumInterval: 300,
        now: now
    ))
    XCTAssertFalse(TokenStore.shouldRefreshLocalCostSummary(
        updatedAt: now.addingTimeInterval(-299),
        force: false,
        minimumInterval: 300,
        now: now
    ))
}
~~~

- [ ] **Step 2: 运行测试，确认因代理未传递和刷新 helper 缺失而失败**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/TokenStoreGatewayLifecycleTests -only-testing:codexpanelTests/TokenStoreSettingsTests

Expected: 代理 spy 尚未记录默认/账号映射，且 shouldRefreshLocalCostSummary 不存在。

- [ ] **Step 3: 最小实现 TokenStore 接线和刷新修复**

~~~swift
self.openAIAccountGatewayService.updateState(
    accounts: self.accounts,
    quotaSortSettings: self.config.openAI.quotaSort,
    accountUsageMode: effectiveGatewayMode,
    defaultProxy: OpenAIAccountGatewayConfiguredProxy(address: self.config.openAI.aggregateGatewayProxyURL),
    proxyByAccountID: self.aggregateGatewayProxyByAccountID()
)

static func shouldRefreshLocalCostSummary(
    updatedAt: Date?,
    force: Bool,
    minimumInterval: TimeInterval,
    now: Date
) -> Bool {
    force || updatedAt.map { now.timeIntervalSince($0) >= minimumInterval } ?? true
}
~~~

Build aggregateGatewayProxyByAccountID() from OAuth provider accounts and parsed active interop profiles. Update the test spy to retain the passed proxy values. Replace only the redundant guard force || updatedAt == nil with the static predicate so force, throttle and in-flight de-duplication preserve their existing meanings.

- [ ] **Step 4: 运行目标测试，确认通过**

Run: xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -only-testing:codexpanelTests/TokenStoreGatewayLifecycleTests -only-testing:codexpanelTests/TokenStoreSettingsTests

Expected: 两个 test class 均通过。

- [ ] **Step 5: 提交 TokenStore 改动**

~~~bash
git add codexPanel/Services/TokenStore.swift codexPanelTests/TokenStoreGatewayLifecycleTests.swift codexPanelTests/TokenStoreSettingsTests.swift
git commit -m "fix(用量): 恢复本地成本周期刷新"
~~~

### Task 4: 版本、marker 和完整验证

**Files:**
- Modify: codexpanel.xcodeproj/project.pbxproj:477,522
- Modify: docs/development/codexbar-upstream-sync.json
- Modify: docs/superpowers/specs/2026-07-11-codexbar-v1-2-7-selective-sync-design.md
- Modify: docs/superpowers/plans/2026-07-11-codexbar-v1-2-7-selective-sync.md

**Interfaces:**
- Produces: MARKETING_VERSION = 1.5.9 与 marker 的 v1.2.7 / cc1faaa10bab1e07943c1f91b666d2b6749f4eb8 标记。

- [x] **Step 1: 更新版本与 marker**

~~~json
{
  "mergedThroughTag": "v1.2.7",
  "mergedThroughCommit": "cc1faaa10bab1e07943c1f91b666d2b6749f4eb8"
}
~~~

Keep the marker's annotated-tag-object convention and update only the two app MARKETING_VERSION entries from 1.5.8 to 1.5.9.

- [x] **Step 2: 静态检查与全量测试**

Run: git diff --check && xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -derivedDataPath /tmp/codexpanel-v1.5.9-test -resultBundlePath /tmp/codexpanel-v1.5.9-test.xcresult -quiet && xcrun xcresulttool get test-results summary --path /tmp/codexpanel-v1.5.9-test.xcresult

Expected: git diff --check 无输出，test result failedTests: 0。

- [x] **Step 3: Debug/Release build 和隔离运行态检查**

Run: xcodebuild -project codexpanel.xcodeproj -scheme codexpanel -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/codexpanel-v1.5.9-debug -quiet build && xcodebuild -project codexpanel.xcodeproj -scheme codexpanel -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/codexpanel-v1.5.9-release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet build

Expected: 两个 build 退出码均为 0；不安装或触碰正式 home。

- [ ] **Step 4: 请求独立代码审查并处理 Critical/Important 反馈**

Create a review package against origin/main, dispatch a fresh reviewer with the approved design and this plan, then apply and re-review all Critical/Important findings.

- [x] **Step 5: 最终提交**

~~~bash
git add docs/development/codexbar-upstream-sync.json codexpanel.xcodeproj/project.pbxproj docs/superpowers
git commit -m "feat(upstream): 合入 codexbar v1.2.7"
~~~
