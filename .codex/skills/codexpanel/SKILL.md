---
name: codexpanel
description: |
  General Codex Panel repository skill. Use for high-level Codex Panel app operations and to choose the right repo-local skill.
---

# Codex Panel Skill

Use this skill as the general entry point for Codex Panel repository work. Choose the narrower repo-local skill when the task has a specific operational surface.

## Development Isolation

- Xcode Debug builds use the development runtime profile by default.
- Debug home is `~/.codexpanel-dev/home`, not the real production home.
- Use `CODEXPANEL_HOME` for an explicit temporary development home.
- Use `CODEXPANEL_ALLOW_REAL_HOME=1` only for deliberate low-level compatibility checks that must touch the real `~/.codex`.
- See `docs/development-isolation.md` for the repository workflow.

## Skill Routing

- Use `$codexpanel-local-release` when the task is local release packaging, GitHub Release assets, `updates.json`, update-chain validation, or local install cleanup.
- For OpenAI OAuth account import, use the menu bar app and localhost callback flow. Do not hand-edit Codex auth/config files when the app can perform the operation.

## Current Product Boundary

Codex Panel ships only the macOS menu bar app. It does not bundle or install a `codexpanel` / `codexpanel-dev` CLI helper, and it does not register an automation URL scheme. The OAuth callback schemes remain `com.codexpanel.oauth` for Release and `com.codexpanel.dev.oauth` for Debug.

## Safety Rules

- Do not print `access_token`, `refresh_token`, or `id_token`.
- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` unless the user explicitly asks for low-level repair and the app path cannot handle it.
- Keep repo collaboration text in Chinese unless the user asks otherwise.
