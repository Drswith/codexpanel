# CodexBar v1.2.7 选择性同步设计

## 目标

将 `lizhelang/codexbar` 的 v1.2.7 中两项经过筛选的能力带入 Codex Panel：让本地成本摘要的非强制刷新按最小间隔正常生效，并为既有 OpenAI 聚合网关增加显式上游代理路由。该同步映射为 Codex Panel `v1.5.9`，不使用无共同基线的 Git merge。

## 范围

包含：

- 移除 `TokenStore.refreshLocalCostSummary` 中会阻断非强制刷新的早退条件，并保留五分钟最小刷新间隔与并发去重。
- 在 OpenAI 设置中持久化一个可选的聚合网关默认代理地址，并在账号页提供编辑入口。
- 使用已有 OAuth 账号的 `interopProxyKey` 和 `interopProxiesJSON` 作为按账号代理来源。
- 让聚合网关的 HTTP 请求与 WebSocket 请求都选择同一套代理优先级：账号代理 -> 默认代理 -> 既有系统代理策略。
- 为新增配置解析、路由优先级、HTTP/WS 会话选择和成本刷新间隔补充单元测试。

不包含：

- cached token 统计/计费口径调整；该变更需要先用真实 Codex session JSONL 验证字段语义。
- `model_context_window`、GPT-5.6 默认模型或 service tier 迁移。
- Requesty provider、README/营销资源、上游 release feed。
- 认证代理。地址中包含用户名或密码的 URL、以及带认证字段的导入代理 profile 均不参与路由，避免把凭据保存为明文却不能完成代理认证。

## 方案比较

1. 原样移植上游实现：改动最快，但会保留代理用户名/密码持久化而未验证认证是否生效的问题。
2. 只实现默认代理：实现面较小，但会丢弃本仓库已导入的按账号 `proxy_key` 信息。
3. 采用的方案：同时支持默认代理和现有按账号 profile，严格接受无认证 HTTP(S)/SOCKS 端点，并在运行时按账号选择和复用 `URLSession`。它保留产品能力，同时避免不可靠的凭据路径。

## 架构与数据流

`CodexPanelOpenAISettings.aggregateGatewayProxyURL` 是一个可选、向后兼容的配置字段。设置页只编辑该默认值；现有导入流程继续负责保存 proxy profile 和账号 `interopProxyKey`，不新增第二套账号绑定 UI。

`OpenAIAccountGatewayConfiguredProxy` 负责解析默认地址和 interop profile。它只接受 `http`、`https`、`socks`、`socks5`，要求非空 host 与 `1...65535` 的端口，拒绝用户密码。它生成专用 `connectionProxyDictionary`，因此显式选择会覆盖系统代理快照；没有可用显式代理时保留原有 loopback-safe 系统代理行为。

`TokenStore.pushPublishedState()` 将默认代理、解析后的 profile 字典和 OAuth 账号绑定一并交给既有 `OpenAIAccountGatewayService`。服务快照保存默认代理与按账号映射；`upstreamSession(for:)` 的优先级为账号映射、默认代理、既有专用会话。显式代理会话按配置复用并在配置或账号变动后清理。HTTP `bytes(for:)` 与 WebSocket `webSocketTask(with:)` 都必须通过此选择器。

## 错误处理与安全边界

- 无效、禁用、带认证信息或端口越界的代理会被忽略；网关继续使用下一层（默认或系统代理），不会阻断账号路由。
- 代理地址不会写入日志，测试也只使用虚构地址。
- 显式代理只影响聚合网关到 OpenAI 上游的流量，不改变登录、刷新 token、其他 provider 或本机 listener 的网络路径。

## 测试与验收

- 直接发起非强制刷新时，已有 `updatedAt` 但超过最小间隔的本地成本摘要会再次加载；间隔内仍不会重复加载。
- 配置解码兼容旧 JSON；默认代理会持久化；含凭据或非法端口的值不会成为有效代理。
- 账号 profile 覆盖默认代理；未知/禁用 profile 回退默认代理；无显式代理时保留系统代理策略。
- HTTP 与 WebSocket 的测试钩子均验证针对相同账号解析到同一个显式代理会话。
- 全量 `xcodebuild test`、Debug/Release build 和隔离开发态 UI 验证通过后，更新上游 marker 与版本。
