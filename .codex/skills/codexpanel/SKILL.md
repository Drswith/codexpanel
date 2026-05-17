---
name: codexpanel
description: |
  General Codex Panel repository skill. Use for high-level Codex Panel app operations and to choose the right repo-local skill.
  For the installed `codexpanel` CLI Driver V1, prefer `$codexpanel-cli-driver`.
---

# Codex Panel Skill

Use this skill as the general entry point for Codex Panel repository work. Choose the narrower repo-local skill when the task has a specific operational surface.

## Development Isolation

- Xcode Debug builds use the development runtime profile by default.
- Debug home is `~/.codexpanel-dev/home`, not the real production home.
- Debug CLI command is `codexpanel-dev`; Release CLI command is `codexpanel`.
- Use `CODEXPANEL_HOME` for an explicit temporary development home.
- Use `CODEXPANEL_ALLOW_REAL_HOME=1` only for deliberate low-level compatibility checks that must touch the real `~/.codex`.
- See `docs/development-isolation.md` for the repository workflow.

## Skill Routing

- Use `$codexpanel-cli-driver` when the task is to operate the installed app through the `codexpanel` CLI, open/close views, run `state`, run `snapshot`, run `doctor`, validate CLI installation, or inspect native Accessibility output.
- Use `$codexpanel-local-release` when the task is local release packaging, GitHub Release assets, `updates.json`, update-chain validation, or local install cleanup.
- For OpenAI OAuth account import, use the menu bar app and localhost callback flow. Do not hand-edit Codex auth/config files when the app can perform the operation.

## Current CLI Boundary

The shipped Release CLI Driver V1 command is `codexpanel`, not `codexpanel-ctl`. Repository Debug builds use `codexpanel-dev`.

Supported user-facing CLI groups:

```bash
codexpanel view open settings --page usage --wait 3 --json
codexpanel view open menu --wait 3 --json
codexpanel view open login --wait 3 --json
codexpanel view close all --wait 3 --json
codexpanel state --json
codexpanel snapshot --format tree --target auto
codexpanel doctor --json
```

For Debug builds, use the matching development command:

```bash
codexpanel-dev view open settings --page usage --wait 3 --json
codexpanel-dev view open menu --wait 3 --json
codexpanel-dev view open login --wait 3 --json
codexpanel-dev view close all --wait 3 --json
codexpanel-dev state --json
codexpanel-dev snapshot --format tree --target auto
codexpanel-dev doctor --json
```

The V1 driver does not implement account-management commands, generic control refs, `click`, `fill`, `press`, or MCP.

## Safety Rules

- Do not print `access_token`, `refresh_token`, or `id_token`.
- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` unless the user explicitly asks for low-level repair and the app path cannot handle it.
- Prefer native CLI state/snapshot output over visual simulation when inspecting the app.
- Keep repo collaboration text in Chinese unless the user asks otherwise.
