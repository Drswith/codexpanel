# Core + UI 分层边界

本文记录 [issue #13](https://github.com/Drswith/codexpanel/issues/13) 在引入 Rust sidecar 前的 Swift 前置拆分。当前阶段不引入 Rust、不新增 IPC，也不承诺一次迁移全部业务逻辑；目标是先建立可执行、可测试、可渐进替换的边界。

## 目录与依赖方向

```text
codexPanel/                         macOS App / UI 宿主
  Views/                            SwiftUI 界面
  Services/                         现有 macOS 与应用服务
  UI/Adapters/                      UI 模型到 Core 契约的适配层

Packages/CodexPanelCore/            独立 Swift Package
  Sources/CodexPanelCore/           Foundation-only Core
  Tests/CodexPanelCoreTests/        不依赖 Xcode App target 的测试
```

依赖只能从 App/UI 指向 Core：

```text
SwiftUI / AppKit -> UI Adapter -> CodexPanelCore
```

`CodexPanelCore` 不得导入 `AppKit`、`SwiftUI`，也不得引用 `TokenStore`、`CodexPanelConfig`、`CodexPaths` 或窗口生命周期。Core 输入输出必须通过公开契约、值类型和文件系统 port 表达。

## 已迁移的真实链路

本次把「激活 provider/账号后同步 Codex 配置」作为第一条端到端切片：

1. `codexPanel/UI/Adapters/CodexSyncService.swift` 从 UI 模型选择激活 provider 和账号。
2. Adapter 生成 `CodexConfigurationSyncRequest`，并注入当前 runtime profile 的 gateway 地址与 `CodexPaths`。
3. `CodexPanelCore` 校验契约版本和凭据，渲染 `auth.json` 与 `config.toml`。
4. Core 同步用例统一执行备份、安全写入和失败回滚。
5. App 继续通过现有 `CodexSynchronizing` 窄接口调用，因此 `TokenStore` 与 OAuth 账号流程无需知道 Core 的实现细节。

配置规则不再由 UI target 持有第二份实现。Core 测试覆盖 OAuth 聚合网关、兼容 provider 的 Chat Completions 网关、契约版本拒绝、JSON 契约往返和双文件事务回滚；原有 App 回归测试继续覆盖 UI 模型到 Core 的实际映射。

## 契约约束

- `CodexConfigurationSyncRequest.schemaVersion` 当前为 `1`。新增或改变字段语义时必须显式演进版本并保留迁移策略。
- `CodexConfigurationSyncError` 的 raw value 是稳定错误码；UI 负责本地化呈现，调用方不得依赖自由文本判断错误。
- 请求包含 token/API key，只允许在受控的进程内边界中传递。不得打印、埋点、写入诊断包或把完整请求持久化。
- Core 只写入 adapter 明确提供的路径。Debug App 仍通过 `CodexPaths` 使用开发态隔离 home，不得绕过 `CODEXPANEL_HOME` / runtime profile。
- 本次保留现有单进程同步语义，没有新增跨进程锁。引入 sidecar 前，RFC 必须指定唯一写入者、锁粒度、超时、崩溃恢复和旧版本兼容行为。

## CI 与本地验证

Core 不依赖 macOS UI 工具链，可单独运行：

```sh
swift test --package-path Packages/CodexPanelCore
```

GitHub Actions 的 `core (Linux)` job 使用官方 Swift Linux 镜像执行同一命令；macOS `build` job 继续验证 Xcode App/UI 集成和开发态隔离测试。两类门禁分别证明 Core 可移植性与宿主接线正确性。

## 后续迁移与 Rust 接入点

后续切片应沿相同模式迁移配置读取、鉴权状态、扫描与聚合规则，而不是把整个 `TokenStore` 直接搬进 Core。每条链路都应具备：

- 版本化请求/响应；
- 稳定错误码；
- Core 单元/契约测试；
- App adapter 回归测试；
- 敏感字段与路径边界说明。

未来引入 Rust sidecar 时，Swift Client 应在 adapter 后替换执行器，保持 UI 只面向同一契约。业务型 CLI 也必须调用同一执行器或 sidecar；在此之前不在 `codexpanelCLI` 中复制配置渲染和文件写入逻辑。

## 非目标

- 本阶段不引入 Rust、Cargo、IPC 或 sidecar 生命周期管理。
- 不改变现有产品行为、配置格式和 Debug/Release home 规则。
- 不把 AppKit/SwiftUI 界面代码迁入 Core。
- 不宣称 issue #13 已完成；本变更只是其第一条可运行前置切片。
