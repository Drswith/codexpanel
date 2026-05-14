---
name: codexpanel-local-release
description: |
  在 codexpanel 仓库执行本地发版闭环：本地构建 universal app、生成 dmg/zip 与 sha256、生成并上传 updates.json、发布到 GitHub Release、校验更新链路并清理本地安装残留。
  当用户提到本地发版、release 资产上传、updates.json、releases/latest 回退、更新 403 排查、发版后重复应用清理时使用。
---

# CodexPanel Local Release

使用本技能时，优先走仓库现有脚本，不要重复手写打包流程。目标是一次完成“发布可用 + 更新可用 + 本地无残留”闭环。

## 核心约束

- 使用 `scripts/release_local.sh` 作为主入口。
- 维护更新源优先级：`updates.json -> releases/latest -> Releases API`。
- 默认运行时更新源使用 `https://github.com/Drswith/codexpanel/releases/latest/download/updates.json`，不要改为 `raw.githubusercontent.com/.../main/...`。
- 仅接受稳定 release：非 draft、非 prerelease、且包含可安装 `dmg/zip`。
- 任务涉及本地安装/替换 `codexpanel.app` 时，必须做安装残留清理与可见性核对。

## 执行流程

1. 收集上下文并确认边界。
- 读取 `git status --short --branch` 与当前分支。
- 确认是否仅讨论方案；若用户要求落地，则直接执行发布闭环。
- 确认发布版本策略（`major/minor/patch/beta/alpha/rc` 或 `--version`）。

2. 执行本地发布脚本。
- 常用命令：
```bash
scripts/release_local.sh patch --upload upload
scripts/release_local.sh minor --upload create --notes "Release 1.5.0"
```
- 需要无交互时添加 `--yes`，需要仅演练时使用 `--dry-run`。
- 脚本会生成 `dmg/zip`、对应 `sha256`、以及 `updates.json`，并在 `--upload upload/create` 时一并上传。

3. 校验发布资产与更新链路。
- 校验 release 资产齐全：`dmg`、`zip`、`*.sha256`、`updates.json`。
- 校验客户端更新路径说明与实现一致：先读 update feed，再回退 `releases/latest`，最后回退 Releases API。
- 必要时同步仓库副本：
```bash
cp "<dist>/updates.json" docs/updates.json
```

4. 执行安装残留清理与可见性核对。
- 先清理本次构建/安装产生的临时副本（如 `.release-tmp`、`/private/tmp` 下临时目录、staging 副本）。
- 使用 `scripts/check_update_readiness.sh` 或等价命令检查 `mdfind` 与 `lsregister`。
- 目标状态是只保留目标安装副本（通常 `/Applications/codexpanel.app`），避免 App Library/Spotlight 出现重复入口。

5. 输出闭环报告。
- 汇报版本号、tag、release URL、资产完整性、更新检查结论、清理结果。
- 明确未完成项（例如未执行签名/公证、未推送、未上传）。

## 故障处理规则

- 遇到 `403` 时先判断来源：
- `updates.json` 403：通常是 URL 不可访问、被网络策略拦截或资产不存在。
- Releases API 403：常见为匿名限流，说明已落到最后兜底路径。
- 始终优先修复上游 feed 与 latest 路径，不要把 API 兜底当主链路。
- 网络失败时可先按用户默认代理约定重试，再继续深挖。

## 参考资料装载

- 需要完整命令清单时，先读 [references/release-checklist.md](references/release-checklist.md)。
- 需要理解 `updates.json` 字段契约与一致性校验时，读 [references/updates-json-contract.md](references/updates-json-contract.md)。

## 禁止事项

- 不要把 runtime 更新源改成 `main` 分支 raw 文件地址。
- 不要跳过发版后校验与安装清理就结束任务。
- 不要在汇报里泄露敏感 token。
