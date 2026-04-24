---
name: codexpanel
description: |
  Operate Codex Panel's bundled CLI for OpenAI OAuth account login, import, listing, and activation.
  Use when the user mentions codexpanel, OpenAI OAuth login, add account, activate account, or switch account.
---

# Codex Panel CLI Skill

Use this skill when the task is about operating Codex Panel accounts or OAuth flows. Prefer the CLI over the GUI.

## Resolve the binary

Use the first working path:

1. `codexpanel-ctl`
2. `/Applications/codexpanel.app/Contents/MacOS/codexpanel-ctl`
3. Build from the repo:

```bash
xcodebuild -scheme codexpanel-ctl -destination 'platform=macOS' build
```

Then invoke the built binary from Xcode's product directory if needed.

## Standard commands

Interactive human flow:

```bash
codexpanel-ctl openai login
```

Automation / AI flow:

```bash
codexpanel-ctl openai login start --json
codexpanel-ctl openai login complete --flow-id <id> --callback-url <url> --json
```

If only the `code` parameter is available:

```bash
codexpanel-ctl openai login complete --flow-id <id> --code <code> --json
```

List accounts:

```bash
codexpanel-ctl accounts list --json
```

Activate an account:

```bash
codexpanel-ctl accounts activate --account-id <id> --json
```

## Rules

- Prefer `openai login` for a person in a terminal.
- Prefer `login start` + `login complete` for AI or scriptable flows.
- Do not hand-edit `~/.codex/auth.json` or `~/.codex/config.toml` if the CLI is available.
- Never echo or summarize `access_token`, `refresh_token`, or `id_token`.
