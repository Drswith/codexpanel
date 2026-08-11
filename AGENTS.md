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

The app does not ship a `codexpanel` / `codexpanel-dev` CLI helper or an automation URL scheme.
Use the menu bar app directly for user-facing operations.

## 开发态隔离

- Xcode Debug app 默认使用开发态 profile，不应写入真实 `~/.codex` / `~/.codexpanel`。
- Debug 默认 home 是 `~/.codexpanel-dev/home`；其中 `.codex` 与 `.codexpanel` 都属于开发态隔离数据。
- 只有明确做低层迁移或兼容性验证时，才允许设置 `CODEXPANEL_ALLOW_REAL_HOME=1` 让 Debug app 触碰真实 home。
- 需要临时隔离目录时，优先设置 `CODEXPANEL_HOME=/tmp/codexpanel-dev-home` 或测试框架提供的临时目录。
- Debug app 的 bundle id 是 `com.codexpanel.dev`，OAuth URL scheme 是 `com.codexpanel.dev.oauth`。
- Release 正式运行态继续使用真实 `~/.codex` 历史池，OAuth URL scheme 是 `com.codexpanel.oauth`。
- 开发态隔离细节见 `docs/development-isolation.md`。

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

- `$codexpanel-local-release 按仓库约定执行一次本地发版闭环并汇报结果。`
- `$codexpanel 用作 Codex Panel 仓库通用入口，并根据任务转向更具体的 repo-local skill。`
