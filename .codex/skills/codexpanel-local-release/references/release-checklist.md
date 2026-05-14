# codexpanel 本地发版检查清单

## 1. 前置检查

```bash
git fetch --tags
git status --short --branch
gh auth status
```

- 确认当前分支与工作区状态符合预期。
- 确认 `xcodebuild`、`gh`、`git` 可用。
- 确认仓库 `main` 分支保护已开启，且必需检查包含 `build`。

## 2. 执行发版

最常用命令：

```bash
scripts/release_local.sh patch --upload upload
```

常见变体：

```bash
scripts/release_local.sh minor --upload create --notes "Release 1.5.0"
scripts/release_local.sh --version 1.5.1 --upload upload --yes
scripts/release_local.sh patch --dry-run
```

说明：
- `--upload upload`：向已存在 tag 的 release 上传资产。
- `--upload create`：创建 release 并上传资产。
- `--yes`：跳过交互确认。
- `--dry-run`：仅演练，不改文件与 git 状态。

## 3. 产物校验

默认输出目录在脚本日志 `DIST_DIR` 下，应至少包含：

- `codexpanel-<version>-macOS.dmg`
- `codexpanel-<version>-macOS.zip`
- `*.sha256`
- `updates.json`

如需保留仓库可读副本，可同步：

```bash
cp "<dist>/updates.json" docs/updates.json
```

## 4. 更新链路校验

优先级必须保持：

1. `updates.json`
2. `releases/latest`
3. Releases API

关键检查点：

```bash
/usr/libexec/PlistBuddy -c "Print :CodexPanelUpdateFeedURL" codexPanel/Info.plist
/usr/libexec/PlistBuddy -c "Print :CodexPanelGitHubLatestReleaseURL" codexPanel/Info.plist
/usr/libexec/PlistBuddy -c "Print :CodexPanelGitHubReleasesURL" codexPanel/Info.plist
```

- `CodexPanelUpdateFeedURL` 应指向：
  `https://github.com/Drswith/codexpanel/releases/latest/download/updates.json`

## 4.1 PR 与 CI 门禁校验（涉及仓库改动时）

```bash
gh pr checks <pr-number>
```

- 至少确认 `build` 检查通过后再推进合并。
- 不要以绕过保护规则的方式合并到 `main`。

## 5. 发布后清理与可见性核对

先清理临时目录（按本次任务实际路径）：

```bash
rm -rf .release-tmp
```

执行可见性检查：

```bash
scripts/check_update_readiness.sh "/Applications/Codex Panel.app"
```

或手动检查：

```bash
mdfind "Codex Panel.app || codexpanel.app || com.codexpanel"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
  | rg -n "Codex Panel\\.app|codexpanel\\.app|com\\.codexpanel" | head -n 120
```

目标：只保留用户明确需要的安装副本，避免重复入口。
