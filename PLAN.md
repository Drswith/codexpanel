# Codex Panel CLI 原生 UI Driver V1 开发计划

## Summary
V1 先忽略 MCP，交付一个安装后可用的 `codexpanel` CLI，用来替代快捷键、截图和坐标点击中的“打开目标界面 + 观察当前界面结构”部分。

已锁定范围：
- 做 `view` intent：打开/关闭菜单、设置页、登录窗口。
- 做 `state --json`：返回 App 运行状态与可见 Codex Panel UI。
- 做 `snapshot`：通过 macOS Accessibility 采集 Codex Panel 自身窗口的 UI tree。
- 不做业务账号切换命令，不做 `click/fill/press @ref`，不做 MCP。
- CLI 与 App 的视图控制 V1 先走 URL Scheme；snapshot 由 CLI 直接读取 AX tree 并输出到 stdout。

## Key Changes
- 新增 command line target：`codexpanel`。
  - 二进制随 `.app` 打包进 `Contents/Helpers/codexpanel`。
  - 设置页新增“安装 CLI”入口，创建或更新 `~/.local/bin/codexpanel` symlink 指向 helper。
  - CLI 输出默认面向 agent：成功简洁，结构化命令使用 JSON，错误返回非 0 exit code。

- 扩展 App URL router。
  - 保留现有 `com.codexpanel.oauth://login`。
  - 新增通用 scheme：`codexpanel://view/open/settings?page=usage`、`codexpanel://view/open/menu`、`codexpanel://view/close/settings`。
  - App 内新增窄接口 `CodexPanelUICommandRouter`，统一调用现有 `DetachedWindowPresenter`、`OpenAILoginCoordinator`、`MenuBarStatusItemController`。
  - `SettingsWindowView` 增加初始页面参数，支持 `accounts | records | usage | updates`。

- 新增 CLI 命令接口。
  ```sh
  codexpanel view open settings --page accounts|records|usage|updates [--wait 3]
  codexpanel view open menu [--wait 3]
  codexpanel view open login [--wait 3]
  codexpanel view close settings|menu|login|all [--wait 3]
  codexpanel state --json
  codexpanel snapshot --format tree|json --target auto|settings|menu|login|all
  codexpanel doctor --json
  ```

- Snapshot 行为。
  - 只采集 bundle id 为 `com.codexpanel` 的 Codex Panel 窗口、popover、panel。
  - ref 优先来自 accessibility identifier；缺失时生成稳定路径 ref，例如 `@window.openai-settings/sidebar.usage`。
  - 输出 role、title/label、value 摘要、enabled、focused、frame、children。
  - 对 token、API key、password、authorization、secret 类字段统一脱敏。
  - 未获得 Accessibility 权限时，返回明确错误和修复提示，不尝试退回截图识别。

## Implementation Notes
- 不把 CLI 做成第二个 App 进程；CLI 的 UI intent 只负责打开 URL，真实窗口仍由已安装的 Codex Panel App 管理。
- `view open ... --wait` 的等待标准是 AX tree 中出现目标窗口或目标页面标识；超时返回非 0。
- `state --json` 不读取敏感 token，只返回 appRunning、bundlePath、version、visibleWindows、activeSettingsPage、menuVisible、loginVisible、accessibilityTrusted。
- 设置页 CLI 安装只管理 symlink，不自动写 `/usr/local/bin`；如目标目录不存在则创建 `~/.local/bin`。
- 发布脚本需要把 helper 打进 zip/dmg，并在本地安装清理后确认 `/Applications/Codex Panel.app` 仍是唯一可见 App 副本。

## Test Plan
- 单元测试 URL parsing：合法/非法 view URL、settings page 映射、close all 行为。
- 单元测试 CLI argument parsing：命令、默认值、错误码、JSON error shape。
- AppKit 测试：`view open settings --page usage` 能打开设置窗口并选中 usage；close settings 能关闭对应窗口。
- AX snapshot 测试：在测试窗口上生成 tree/json，包含 ref、role、label、frame，并脱敏敏感输入。
- 集成验证：
  ```sh
  codexpanel view open settings --page usage --wait 3
  codexpanel snapshot --format tree --target settings
  codexpanel state --json
  codexpanel view close settings --wait 3
  ```
- 发版验证：构建 Release app、确认 helper 存在、通过设置页安装 symlink、运行 `codexpanel doctor --json`。

## Test Hardening Plan

当前测试足以支撑 V1 初步落地和本次 Release 构建异常闭环，但还不够支撑长期维护。后续测试补强按以下优先级推进。

### Current Coverage

- `CodexPanelUICommandRouterTests` 已覆盖 URL parsing、settings page 降级、`close all` 解析、`open all` unsupported。
- `CodexPanelCLIInstallServiceTests` 已覆盖 helper 缺失、创建 symlink、替换旧路径、读取 linked target。
- `CoalescedBackgroundRefreshControllerTests` 已覆盖本次 Release 编译崩溃相关类的关键刷新语义。
- 手动集成验收已覆盖：
  ```sh
  codexpanel view open settings --page usage --wait 3 --json
  codexpanel snapshot --format tree --target settings
  codexpanel state --json
  codexpanel view close settings --wait 3 --json
  ```
- 本地发版脚本已通过 `--upload none` 端到端验证，确认 helper 进入 universal app，zip/dmg/sha256/updates.json 可生成。

### Gaps

- CLI 参数解析、默认值、互斥约束、错误码和 JSON error shape 仍缺少单元测试。
- `snapshot` 的 ref 生成稳定性、树结构、窗口筛选和敏感文本脱敏仍缺少纯单元测试。
- `view --wait` 的成功、超时、App 未运行、Accessibility 未授权等路径仍缺少可重复测试。
- UI router 当前主要验证 URL 解析，还缺少对“打开设置并选中目标 page”“菜单打开/关闭幂等”“登录窗口开/关”的行为测试。
- 发版脚本缺少轻量自动测试来固定 helper 必须进包、可选 debug dylib 缺失不应失败、`updates.json` 字段稳定。

### Phase 1: Make CLI Core Testable

- 将 `codexpanelCLI/main.swift` 中的 CLI parser、error payload、snapshot redaction、ref slug/path 生成拆到可单测的 Swift 文件。
- 为 parser 增加测试：
  - `view open settings` 默认 page 为 `accounts`。
  - `--page` 只允许用于 `view open settings`。
  - `view open all` 返回 exit code `6`。
  - 非法 `--wait`、未知 command、未知 option 返回 exit code `2`。
  - `state` 和 `doctor` 默认输出 JSON。
- 为 error shape 增加测试：所有结构化错误稳定输出 `{ "error": { "code", "message", "hint" } }`。

### Phase 2: Snapshot Unit Tests

- 为 AX snapshot 中不依赖真实 AX 的逻辑建立纯函数测试：
  - ref 优先使用 accessibility identifier。
  - 缺失 identifier 时使用父路径 + role/title/label slug + sibling index。
  - 同级同名节点生成稳定递增 ref。
  - `token`、`api key`、`apikey`、`password`、`secret`、`authorization`、`bearer`、`refresh_token`、`access_token`、`id_token` 命中 `<redacted>`。
  - `sk-`、`sess-` 前缀和疑似长 token/JWT 文本被掩码。
- 为 tree/json renderer 增加固定 fixture 测试，避免输出字段和缩进格式无意漂移。

### Phase 3: View Wait And State Tests

- 为 wait 判断逻辑抽象 `AppStateProvider`，用 fake state 测试：
  - settings/menu/login open 目标出现即成功。
  - settings/menu/login close 目标消失即成功。
  - `close all` 需要 settings、menu、login 全部不可见。
  - 超时返回 exit code `5`。
  - Accessibility 未授权返回 exit code `4`。
- 为 `state --json` 增加 fixture 测试：
  - App 未运行时 `appRunning=false`、`pid=null`、`visibleWindows=[]`。
  - Accessibility 未授权时不尝试读取窗口树，但仍返回 `appRunning` 和 `pid`。
  - App 运行且有窗口时 `menuVisible` 和 `visibleWindows` 稳定。

### Phase 4: UI Router Behavior Tests

- 为 `CodexPanelUICommandRouter` 引入窄依赖协议或测试 spy，避免测试直接依赖真实窗口生命周期。
- 覆盖：
  - `open settings?page=usage` 调用 settings presenter 且 page 为 `usage`。
  - `open settings` 缺省 page 为 `accounts`。
  - `open menu`/`close menu` 幂等。
  - `open login`/`close login` 调用登录 coordinator。
  - `close all` 同时请求关闭 settings、menu、login。

### Phase 5: Release Packaging Regression

- 给 `scripts/release_local.sh` 增加轻量脚本验收，至少覆盖：
  - universal app 必须包含 `Contents/Helpers/codexpanel`。
  - helper 必须可执行。
  - helper 必须和主程序一样为 universal 二进制。
  - `Contents/MacOS/*.debug.dylib` 和 `__preview.dylib` 缺失时不阻断打包。
  - `updates.json` 包含 version、dmg、zip、sha256、downloadURL。
- 该验收可以先以 `scripts/verify_release_artifacts.sh <universal-app> <dist-dir>` 形式实现，由 `release_local.sh` 在打包后调用。

### Acceptance Criteria

- 新增测试可在本地用一条命令跑通，不依赖真实用户 token，不打印敏感信息。
- 非 UI 的 CLI parser、snapshot redaction、ref 生成测试不要求 Accessibility 授权。
- 需要真实 AX 的集成测试必须可跳过，并在跳过时输出明确原因。
- Release 验收失败时错误信息指向具体缺失项，例如 helper 缺失、helper 不可执行、架构不完整或 `updates.json` 字段缺失。
- 完成本计划后，CLI V1 的回归信心应从“可手动验收”提升到“核心语义可自动防回归”。

## Assumptions
- V1 的目标是 agent-friendly 原生 UI driver，不是业务自动化 CLI。
- V1 snapshot 需要用户授予 Accessibility 权限；不绕过系统权限模型。
- V1 不实现通用 ref 操作；`click/fill/press @ref` 留到 V2。
- V1 不引入 Swift ArgumentParser 依赖，优先用轻量自研 parser，避免先改包管理结构。
