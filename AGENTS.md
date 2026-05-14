# codexpanel 仓库协作约定

## 默认工作语言

- 本仓库的默认工作语言是简体中文。
- 代理、脚本说明、协作文本、交付说明默认使用中文，除非用户明确要求英文，或上游平台/协议强制要求英文。

## 文案语言范围

以下内容默认使用中文：

- Git 提交信息的标题与正文
- Pull Request 标题、描述、评审回复和变更摘要
- Release 标题、Release Notes、发布说明
- 构建包、安装包、构建产物上传时附带的说明文字
- 面向仓库协作的计划、结论、执行记录和汇报

## 保留原文的内容

以下内容不要为了“中文化”而强行翻译：

- 代码标识符、类型名、函数名、变量名
- 命令、路径、配置键、环境变量名
- API 字段、协议字段、第三方平台固定字段
- 构建产物文件名、安装包文件名、版本号、标签名

## 提交协议补充

- 提交信息默认写中文。
- 如果存在必须遵守的上层提交协议或固定 trailer 键名，保留协议要求的键名，其余提交内容和 trailer 值使用中文。
- 除非用户明确要求，不要在这个仓库里默认产出英文提交信息或英文发布说明。

# Codex Panel Repository Guidance

This repository ships a single operator surface:

- the macOS menu bar app

For OpenAI OAuth account import, use the menu bar app and its localhost callback listener.

The app also ships an agent-facing native CLI driver named `codexpanel`.
Use it for top-level UI intent routing and native Accessibility inspection instead of visual simulation when possible.
V1 supports `view`, `state`, `snapshot`, and `doctor`; it does not support generic `click` / `fill` / `press` operations or MCP.

## Safety rules

- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` when Codex Panel can perform the operation.
- Do not print `access_token`, `refresh_token`, or `id_token` in logs, output, or summaries.
- If low-level repair is explicitly required, mention that the normal path is the Codex Panel app before editing auth/config files directly.

## 本地安装清理

- 只要本次任务涉及本地构建、安装、替换或发布 `codexpanel.app`，结束前必须做安装清理，不要留下会在 App Library、Spotlight 或 Launch Services 中表现为“多个 Codex Panel”的残留。
- 默认必须清理本次任务产生或显然属于构建/安装残留的 `codexpanel.app` 副本与目录，例如仓库内 build/staging 目录、`DerivedData` 产物、`/private/tmp` 下的临时安装目录、临时挂载出的测试副本。
- 默认必须核对最终可见性：`mdfind`、`lsregister` 或等价检查应只剩目标安装副本，通常是 `/Applications/codexpanel.app`。
- 如果系统仍显示重复入口，代理必须继续清理 Launch Services / Spotlight 残留，直到重复入口消失或确认只剩用户明确保留的副本。
- 不要擅自删除用户主动保存的归档、DMG、备份或仓库外长期保存副本；只有对临时构建产物和明确残留才默认清理。遇到非临时、非生成目录中的额外副本时，先说明再处理。

## 仓库内 Skill 调用提示

- 不要依赖 `/` 菜单能枚举出所有本地 skill。
- 对仓库内 skill，优先使用 `$skill-name` 显式触发。
- 项目级通用 skill 源文件统一放在 `.agents/skills/<skill-name>/SKILL.md`。
- `.codex/skills/<skill-name>` 与 `.cursor/skills/<skill-name>` 可以作为 symlink 指向 `.agents/skills/<skill-name>`，让 Codex 与 Cursor 开发者共用同一份说明。
- 修改共享 skill 时，优先编辑 `.agents/skills/...` 下的源文件，不要分别维护 `.codex` 与 `.cursor` 两份拷贝。

本仓库常用示例：

- `$codexpanel-cli-driver 打开 Codex Panel 设置页、读取 state/snapshot，或排查 CLI 安装与 Accessibility 权限。`
- `$codexpanel-local-release 按仓库约定执行一次本地发版闭环并汇报结果。`
- `$codexpanel 用作 Codex Panel 仓库通用入口，并根据任务转向更具体的 repo-local skill。`

## Codex Panel CLI Driver 使用边界

- 已安装 CLI 命令名是 `codexpanel`，不是旧的 `codexpanel-ctl`。
- 需要 agent 友好地操作界面时，优先使用 `$codexpanel-cli-driver`。
- `snapshot` 与 `view --wait` 依赖 macOS Accessibility 授权；未授权时应明确说明权限阻塞，不要退回到截图/OCR 伪装成功。
- V1 只能打开/关闭已知视图并读取原生结构；不要承诺任意控件点击、输入或 ref action。

常用命令：

```bash
codexpanel view open settings --page usage --wait 3 --json
codexpanel view open menu --wait 3 --json
codexpanel view close all --wait 3 --json
codexpanel state --json
codexpanel snapshot --format tree --target auto
codexpanel doctor --json
```
