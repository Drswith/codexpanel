---
name: codexpanel-cli-driver
description: |
  Operate Codex Panel through its installed `codexpanel` CLI Driver V1 instead of visual simulation.
  Use when an agent needs to open or close Codex Panel views, read app state, capture native Accessibility snapshots, verify CLI installation, or troubleshoot the agent-friendly UI driver.
---

# CodexPanel CLI Driver

Use this skill when the user wants an agent to operate the installed Codex Panel macOS app through the native `codexpanel` CLI. The goal is to use app intent routes and Accessibility snapshots instead of screenshots, mouse clicks, keyboard shortcuts, or OCR.

## Repository Layout

This skill's canonical source is:

```text
.agent/skills/codexpanel-cli-driver/SKILL.md
```

Codex and Cursor integrations should consume the same source through symlinks:

```text
.codex/skills/codexpanel-cli-driver -> ../../.agent/skills/codexpanel-cli-driver
.cursor/skills/codexpanel-cli-driver -> ../../.agent/skills/codexpanel-cli-driver
```

When updating this skill, edit the `.agent` source and keep the symlinks intact.

## Scope

The V1 CLI driver provides:

- `view`: open and close native Codex Panel views.
- `state`: read structured app state.
- `snapshot`: capture the app's native Accessibility tree.
- `doctor`: inspect installation, helper, symlink, and permission status.

The V1 CLI driver does not provide generic `click`, `fill`, `press`, or MCP. Do not invent those commands. If a task needs arbitrary control activation, first use `snapshot` to inspect native structure, then explain that V1 can only navigate top-level views; leave ref-based actions for a later CLI version.

## Resolve The Binary

Prefer the user-installed command:

```bash
codexpanel doctor --json
```

If `codexpanel` is not on `PATH`, try the bundled helper in the installed app:

```bash
"/Applications/Codex Panel.app/Contents/Helpers/codexpanel" doctor --json
```

If the helper exists but `~/.local/bin/codexpanel` is missing, ask the user to run the app's Settings action "安装 CLI", or use the app UI if the task is explicitly about validating installation.

For repository development builds, build the app target so the helper is copied into the app bundle:

```bash
xcodebuild -scheme codexpanel -destination 'platform=macOS' build
```

Do not use the old `codexpanel-ctl` name for CLI Driver V1. The shipped command is `codexpanel`.

## First Checks

Start with:

```bash
codexpanel doctor --json
codexpanel state --json
```

Interpret the result before attempting view or snapshot commands:

- `appInstalled=false`: the app bundle cannot be found from Launch Services or the helper context.
- `appRunning=false`: `view open ...` may launch or route to the app through URL Scheme, but `snapshot` requires the app process to be running.
- `helperBundled=false`: the app was not packaged with `Contents/Helpers/codexpanel`.
- `cliSymlinkExists=false`: the helper may still work by full path, but the user-facing command has not been installed.
- `accessibilityTrusted=false`: `snapshot` and `view --wait` cannot reliably read AX state. Return a clear permission note instead of falling back to screenshots.

## View Commands

Open a settings page:

```bash
codexpanel view open settings --page accounts --wait 3 --json
codexpanel view open settings --page records --wait 3 --json
codexpanel view open settings --page usage --wait 3 --json
codexpanel view open settings --page updates --wait 3 --json
```

If `--page` is omitted for settings, the default is `accounts`.

Open app surfaces:

```bash
codexpanel view open menu --wait 3 --json
codexpanel view open login --wait 3 --json
```

Close app surfaces:

```bash
codexpanel view close settings --wait 3 --json
codexpanel view close menu --wait 3 --json
codexpanel view close login --wait 3 --json
codexpanel view close all --wait 3 --json
```

Rules:

- `view open all` is not supported and should return exit code `6`.
- `--page` is valid only for `view open settings`.
- Use `--wait` when the next step depends on the view being visible or closed.
- If `--wait` fails with Accessibility permission errors, do not retry with screenshots unless the user explicitly asks for visual operation.

## State Commands

Read current structured state:

```bash
codexpanel state --json
```

Expected fields:

- `appRunning`: whether the Codex Panel process is running.
- `appVersion`: installed/running app version when resolvable.
- `pid`: process ID when running.
- `menuVisible`: whether the menu surface is visible according to AX.
- `visibleWindows`: stable window refs such as `@codexpanel.window.openai-settings`.
- `accessibilityTrusted`: whether AX permission is granted to the CLI process.

Use `state --json` for quick readiness checks and for validating `view close ...` operations when a full snapshot is unnecessary.

## Snapshot Commands

Capture the native Accessibility tree:

```bash
codexpanel snapshot --format tree --target auto
codexpanel snapshot --format json --target auto
```

Target specific surfaces:

```bash
codexpanel snapshot --format tree --target settings
codexpanel snapshot --format json --target menu
codexpanel snapshot --format json --target login
codexpanel snapshot --format json --target all
```

Target behavior:

- `auto` prefers `settings`, then `menu`, then `login`; if none match, it includes all windows.
- `settings`, `menu`, and `login` filter to that surface only.
- `all` returns every Codex Panel AX window/panel collected from the app process.

Snapshot node shape:

- `ref`: stable node reference. Accessibility identifiers are preferred; otherwise path refs are generated.
- `role`: AX role such as `AXButton`, `AXGroup`, `AXStaticText`.
- `title`, `label`, `valueSummary`: summarized text where available.
- `enabled`, `focused`: boolean state when available.
- `frame`: native screen frame when available.
- `children`: nested AX nodes.

Sensitive text is redacted when it looks like a token, API key, password, secret, authorization header, bearer token, refresh/access/id token, `sk-...`, `sess-...`, long token-like text, or JWT-like text. Do not print raw token values from snapshots.

## Standard Agent Workflows

Open a specific settings page and inspect it:

```bash
codexpanel view open settings --page usage --wait 3 --json
codexpanel snapshot --format tree --target settings
```

Open the menu and inspect current controls:

```bash
codexpanel view open menu --wait 3 --json
codexpanel snapshot --format json --target menu
```

Close all managed surfaces:

```bash
codexpanel view close all --wait 3 --json
codexpanel state --json
```

Validate CLI installation:

```bash
codexpanel doctor --json
```

When reporting results to the user, summarize the relevant fields and refs. Do not paste a full JSON snapshot unless the user specifically asks for it.

## Exit Codes

- `0`: success.
- `1`: unknown error.
- `2`: invalid arguments.
- `3`: app unavailable or not running for commands that require a running app.
- `4`: Accessibility permission denied.
- `5`: wait timeout.
- `6`: route unsupported.

Use exit codes to distinguish a user-fixable environment issue from a real command or app regression.

## Troubleshooting

If `codexpanel` is not found:

```bash
ls -l ~/.local/bin/codexpanel
ls -l "/Applications/Codex Panel.app/Contents/Helpers/codexpanel"
```

If the helper is missing from the app, verify the packaged app:

```bash
test -x "/Applications/Codex Panel.app/Contents/Helpers/codexpanel"
```

If `snapshot` or `view --wait` returns exit code `4`, the CLI process does not have Accessibility permission. Ask the user to enable it in System Settings > Privacy & Security > Accessibility. Do not claim the UI is unavailable; say the native AX read path is blocked.

If `view open ...` returns exit code `3`, verify the installed app and URL routing:

```bash
codexpanel doctor --json
open "codexpanel://view/open/settings?page=usage"
```

If `view --wait` returns exit code `5`, check whether the app opened but AX state did not reflect the target:

```bash
codexpanel state --json
codexpanel snapshot --format tree --target all
```

## Development Validation

For CLI driver changes in this repository, run targeted tests first:

```bash
xcodebuild -scheme codexpanel -destination 'platform=macOS' test \
  -only-testing:codexpanelTests/CodexPanelCLIAccessibilityIntegrationTests \
  -only-testing:codexpanelTests/CodexPanelCLIArgumentParserCoreTests \
  -only-testing:codexpanelTests/CodexPanelCLIProcessTests \
  -only-testing:codexpanelTests/CodexPanelCLISnapshotCoreTests \
  -only-testing:codexpanelTests/CodexPanelCLISnapshotWindowSelectionCoreTests \
  -only-testing:codexpanelTests/CodexPanelCLIViewWaitCoreTests \
  -only-testing:codexpanelTests/CodexPanelCLIStateCoreTests \
  -only-testing:codexpanelTests/CodexPanelUICommandRouterTests \
  -only-testing:codexpanelTests/ReleaseArtifactVerificationScriptTests
```

Validate Release packaging when bundle layout or helper installation changes:

```bash
xcodebuild -scheme codexpanel -configuration Release -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

If running the full suite, report any unrelated existing failures separately from CLI driver regressions.

## Safety Rules

- Do not manually edit `~/.codex/auth.json` or `~/.codex/config.toml` as a substitute for Codex Panel behavior.
- Do not expose token values from snapshots, logs, JSON, or summaries.
- Do not use screenshots, OCR, or keyboard shortcuts when `codexpanel view/state/snapshot` can provide the needed operation or evidence.
- Do not assume the V1 CLI can activate arbitrary controls; it can open/close known views and read native state.
- Keep user-facing instructions in Chinese unless the user asks otherwise.

## Invocation

Explicitly invoke this skill as:

```text
$codexpanel-cli-driver 打开设置页 usage 并读取原生 snapshot。
```

If the UI skill menu does not list repository-local skills, explicit `$skill-name` invocation is still valid.
