# 开发态隔离说明

本仓库的 Debug 构建默认运行在开发态 profile 下。目标是让 Xcode Debug app、开发态 CLI、测试和未来 sidecar 不会误写正式安装使用的真实 `~/.codex` / `~/.codexpanel`。

## 运行态边界

Release 正式运行态保持产品行为：

- app bundle id：`com.codexpanel`
- URL scheme：`codexpanel`
- CLI 命令：`codexpanel`
- 默认 home：真实用户 home
- Codex 历史池：真实 `~/.codex`
- OAuth callback：`http://localhost:1455/auth/callback`
- OpenAI gateway：`http://localhost:1456/v1`
- OpenRouter gateway：`http://localhost:1457/v1`

Debug 开发态默认隔离：

- app bundle id：`com.codexpanel.dev`
- URL scheme：`codexpanel-dev`
- CLI 命令：`codexpanel-dev`
- 默认 home：`~/.codexpanel-dev/home`
- Codex 历史池：`~/.codexpanel-dev/home/.codex`
- Codex Panel 状态：`~/.codexpanel-dev/home/.codexpanel`
- OAuth callback：`http://localhost:1555/auth/callback`
- OpenAI gateway：`http://localhost:1556/v1`
- OpenRouter gateway：`http://localhost:1557/v1`

正式 Release 仍然共享真实 `~/.codex` 历史池，这是产品核心行为。开发态隔离只用于本地开发、测试和 agent 调试，不改变正式用户的数据模型。

## Xcode Debug Run

本地开发默认用 Xcode 打开 `codexpanel.xcodeproj`，运行 `codexpanel` scheme 的 Debug 配置即可。不要为了“模拟真实环境”手动把 Debug app 指向真实 `~/.codex`。

Debug app 首次运行会使用：

```bash
~/.codexpanel-dev/home/.codex
~/.codexpanel-dev/home/.codexpanel
```

如果需要指定一次性隔离目录，可以设置：

```bash
CODEXPANEL_HOME=/tmp/codexpanel-dev-home
```

只有在明确做低层迁移或兼容性验证时，才允许使用：

```bash
CODEXPANEL_ALLOW_REAL_HOME=1
```

这个开关会让 Debug app 直接使用真实 home，可能写入真实 `~/.codex/auth.json`、`~/.codex/config.toml` 和 `~/.codexpanel` 状态。使用前必须确认当前任务确实需要触碰正式数据。

## 开发态 CLI

Release app 安装的正式 CLI 是：

```bash
codexpanel doctor --json
codexpanel state --json
codexpanel view open settings --page usage --wait 3 --json
```

Debug app 安装的开发态 CLI 是：

```bash
codexpanel-dev doctor --json
codexpanel-dev state --json
codexpanel-dev view open settings --page usage --wait 3 --json
```

开发态 CLI 通过 `codexpanel-dev://` 路由到 `com.codexpanel.dev`，不应拿正式 `codexpanel` 命令去操作 Debug app。验证 Debug app 时，如果 `codexpanel-dev` 未在 `PATH` 中，先从 Debug app 设置页安装 CLI，或直接使用构建产物内的 helper。

## 测试

测试默认会设置临时 `CODEXPANEL_HOME`，避免污染真实用户目录。关键防回归测试包括：

```bash
xcodebuild test \
  -project codexpanel.xcodeproj \
  -scheme codexpanel \
  -destination 'platform=macOS' \
  -only-testing:codexpanelTests/CodexPanelRuntimeProfileTests \
  -only-testing:codexpanelTests/CodexPanelCLIInstallServiceTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

这些测试必须保证：

- 未设置 `CODEXPANEL_HOME` 时，Debug profile 的 `.codex` / `.codexpanel` 根目录不等于真实 home 下的正式路径。
- Debug identity 使用 `codexpanel-dev`、`codexpanel-dev://` 和 `com.codexpanel.dev`。
- Debug CLI 安装目标是隔离 home 下的 `~/.local/bin/codexpanel-dev`，不会覆盖正式 `codexpanel` symlink。

新增 sidecar 或本地 listener 时，优先把路径、端口和命令名挂到 runtime profile，再补一条 Debug/Release 差异测试。
