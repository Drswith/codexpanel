# 开发态隔离说明

本仓库的 Debug 构建默认运行在开发态 profile 下。目标是让 Xcode Debug app、测试和未来 sidecar 不会误写正式安装使用的真实 `~/.codex` / `~/.codexpanel`。

## 运行态边界

Release 正式运行态保持产品行为：

- app bundle id：`com.codexpanel`
- OAuth URL scheme：`com.codexpanel.oauth`
- 默认 home：真实用户 home
- Codex 历史池：真实 `~/.codex`
- OAuth callback：`http://localhost:1455/auth/callback`
- OpenAI gateway：`http://localhost:1456/v1`
- OpenRouter gateway：`http://localhost:1457/v1`

Debug 开发态默认隔离：

- app bundle id：`com.codexpanel.dev`
- OAuth URL scheme：`com.codexpanel.dev.oauth`
- 默认 home：`~/.codexpanel-dev/home`
- Codex 历史池：`~/.codexpanel-dev/home/.codex`
- Codex Panel 状态：`~/.codexpanel-dev/home/.codexpanel`
- OAuth callback：`http://localhost:1555/auth/callback`
- OpenAI gateway：`http://localhost:1556/v1`
- OpenRouter gateway：`http://localhost:1557/v1`

正式 Release 仍然共享真实 `~/.codex` 历史池，这是产品核心行为。开发态隔离只用于本地开发、测试和 agent 调试，不改变正式用户的数据模型。

## Xcode Debug Run

菜单栏面板使用 `MenuBarExtra(.window)` 的系统窗口，不再使用带尖角的 `NSPopover`。面板仍直接承载原有 `MenuBarView`，宽度、内部控件和按系统版本设定的外层 6/8 点边距保持不变，不额外绘制背景或叠加留白。原有开关快捷键继续连接到这个系统窗口；macOS 27 使用展开会话，较旧系统使用按钮动作。快捷键注册规则不因这次宿主替换而改变。

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

## 测试

测试默认会设置临时 `CODEXPANEL_HOME`，避免污染真实用户目录。关键防回归测试包括：

```bash
xcodebuild test \
  -project codexpanel.xcodeproj \
  -scheme codexpanel \
  -destination 'platform=macOS' \
  -only-testing:codexpanelTests/CodexPanelRuntimeProfileTests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

这些测试必须保证：

- 未设置 `CODEXPANEL_HOME` 时，Debug profile 的 `.codex` / `.codexpanel` 根目录不等于真实 home 下的正式路径。
- Debug identity 使用 `com.codexpanel.dev` bundle id 和 `com.codexpanel.dev.oauth` OAuth URL scheme。
- Debug 和 Release 使用不同的本地端口，避免回调与 gateway 互相占用。

新增 sidecar 或本地 listener 时，优先把路径和端口挂到 runtime profile，再补一条 Debug/Release 差异测试。

## 原生菜单交互验证入口

Debug 构建支持全局快捷键 `Control + Option + Shift + Command + 9`，用于展开实际菜单面板。面板已展开时再次触发不会关闭；Release 不注册此组合，也不包含对应处理入口。

测试时先启动隔离的 Debug app，在任意可操作的桌面应用中发送该组合，再绑定开发版已展开的面板执行 UI 验证。此入口与 CLI、URL scheme 无关。快捷键独立注册，某一组合被正式版或其他实例占用时不会撤销其余入口。`app-lifecycle.jsonl` 中的 `status_item_shortcut_registered`（identifier 3）和 `status_item_menu_opened`（trigger `debug_keyboard_shortcut`）可分别证明注册与面板展示；它们不能代替最终 UI 内容和点击结果的验证。

### 原生辅助功能树的入口

菜单栏面板展开后，`AXWindows` 仍可能返回空列表；实际内容位于应用的状态栏 `AXMenuBar` → `AXMenuExtra` → `AXPopover` 子树。只按普通窗口查找的 UI 工具可能因此超时，这不代表应用主线程或辅助功能接口失去响应。验证时先限定验证进程，再沿状态栏子树读取、展开菜单，并在每次操作后重新读取元素路径。原生菜单项支持 `AXPick`，选择后还应核对界面显示与隔离配置文件。

若当前 UI 工具不支持这条路径，使用其他原生 AX/CGEvent 工具前需遵守当前工具的授权约束。认证与路由同步可通过隔离目录里的供应商 fixture 重放，并核对模型相关配置在切换前后保持一致。
