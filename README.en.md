# codexpanel

Keep Codex Desktop context and session history in one shared `~/.codex` pool while switching accounts or providers.

`codexpanel` is a macOS menu bar utility for Codex Desktop users. It is not trying to replace Codex. It narrows in on the part of the workflow where account or provider switching tends to fragment context and session continuity.

> Switching account or provider should not mean splitting your original Codex session pool into multiple homes.

## At A Glance

- Keep one shared `~/.codex` instead of creating a separate `CODEX_HOME` per account
- Manage OpenAI OAuth, OpenAI-compatible providers, and multiple API keys from the menu bar
- Support both **manual switch** and **aggregate gateway** modes for OpenAI accounts
- Scan local sessions directly for usage, token, and cost estimates
- Make switching affect future sessions without breaking the existing history pool

## Problem It Solves

If you switch often between official OpenAI accounts, relay backends, or OpenAI-compatible providers, the common failure mode is always similar:

- configuration changes, but context feels disconnected
- session files still exist on disk, but history feels fragmented after switching
- manually editing config files is tedious and error-prone

`codexpanel` is meant to make that switching workflow feel like one continuous Codex workspace instead of several loosely related homes.

## Interface and Settings

The menu bar shows costs, OpenAI quota, and provider accounts. Settings includes Accounts, Usage, Diagnostics, and About, with automatic saving.

The menu bar icon remains present while the app runs. The app no longer stores or reads an icon visibility preference. Reopening the app from Finder or Spotlight shows the panel.

Codex owns the model, review model, reasoning effort, and service tier. Startup, account/provider switching, and aggregate-mode changes only synchronize authentication and routing. Existing model settings are preserved, and absent keys stay absent. Third-party gateways use the model sent by Codex rather than a stored Panel model.

## One Shared `~/.codex` Session Pool

Many multi-account workflows isolate each account by creating a separate `CODEX_HOME`. That gives strong separation, but also creates obvious tradeoffs:

- history gets split across multiple directories
- switching can feel like your previous context disappeared
- finding the right session becomes harder

`codexpanel` takes the opposite approach:

- keep a single `~/.codex`
- preserve `~/.codex/sessions` and `~/.codex/archived_sessions` as one shared history pool
- write the active provider / account into `~/.codex/config.toml` and `~/.codex/auth.json`
- let switching affect only future requests and future sessions

That is the main value of the app: switching account or provider does not mean splitting the original Codex history pool.

## Features

- Multiple OpenAI OAuth accounts
- Multiple OpenAI-compatible providers
- Multiple API-key accounts under the same provider
- Fast switching from the menu bar
- Dual OpenAI account modes: **manual switch / aggregate gateway**
- OpenAI account CSV import / export
- OpenAI account ordering: quota-weighted or manual order
- One-click diagnostics export with the latest matching crash report
- Local usage and cost estimates
- Runtime version detection from GitHub Releases plus a manual "Check for Updates" entry

Settings includes Accounts, Usage, Diagnostics, and About. Configure the model, reasoning effort, and service tier in Codex.

Local usage and cost estimates are derived from:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

So you can inspect token usage and estimated cost directly from local session history.

The current UI also covers a few newer workflow details that the older README did not show clearly:

- OpenAI accounts can run in either **manual switch** mode or **aggregate gateway** mode
- OpenAI OAuth accounts can be imported from or exported to CSV
- Settings also let you choose whether OpenAI accounts are shown by quota-weighted ranking or your own manual order
- the settings window can export a GitHub-issue-ready diagnostics bundle with the latest matching crash report plus runtime lifecycle logs

## Version Checks and Updates

Fixed clients now scan the GitHub Releases list at runtime and choose the **first installable stable release**. The app still performs a non-blocking check on launch, and the menu bar UI also exposes a manual "Check for Updates" action.

The current boundary is intentionally narrow:

- the current strategy is still **guided download / install**
- when a newer version exists, codexpanel shows it in the menu/status UI so you can continue with the matching installer asset
- runtime checks skip `draft`, `prerelease`, and any release that does not ship installable `dmg` or `zip` assets
- the current build does **not** pretend that automatic app replacement and restart are already available
- if you already installed an earlier build with the same version number, a same-version reissue will usually not appear as an upgrade automatically; you must download the reissued build manually

## Who This Is For

`codexpanel` is useful if:

- you use both official OpenAI accounts and third-party OpenAI-compatible providers
- you keep multiple API keys under the same provider
- you do not want to edit `config.toml` manually every time you switch
- you want to preserve one shared `~/.codex` history pool and resume experience

## Star History

<p align="center">
  <a href="https://star-history.com/#Drswith/codexpanel&Date">
    <picture>
      <source
        media="(prefers-color-scheme: dark)"
        srcset="https://api.star-history.com/svg?repos=Drswith/codexpanel&type=Date&theme=dark"
      />
      <source
        media="(prefers-color-scheme: light)"
        srcset="https://api.star-history.com/svg?repos=Drswith/codexpanel&type=Date"
      />
      <img
        alt="codexpanel Star History Chart"
        src="https://api.star-history.com/svg?repos=Drswith/codexpanel&type=Date"
      />
    </picture>
  </a>
</p>

## OpenAI Login Flow

OpenAI login currently uses a browser-based authorization flow with localhost callback capture plus a manual fallback. The entry point is the person-plus button in the bottom toolbar:

1. Click the login button
2. Finish authorization in the browser
3. When the browser reaches `http://localhost:1455/auth/callback?...`, codexpanel captures the callback automatically
4. codexpanel completes token exchange and imports the account

If automatic capture fails, you can still paste the full callback URL or the raw `code` back into the window manually.

## Cost Notes

The displayed values are **local usage estimates**, not official billing numbers.

Important caveats:

- token counts are the more stable metric
- dollar values are estimated from pricing tables
- for custom OpenAI-compatible providers, displayed cost may differ from actual upstream billing

If a third-party provider uses a different pricing model than OpenAI, the dollar amount shown in the app should be treated as an approximation only.

## Project Scope

The current version focuses on:

- multi-account management
- multi-provider switching
- a shared `~/.codex` session pool
- local usage and cost summaries

This repository does not bundle any private provider, API key, or personal account configuration. You add your own configuration locally.

## Requirements

- macOS 13+
- [Codex Desktop / CLI](https://github.com/openai/codex)
- Xcode 15+ if you want to build locally

## Build Locally

```sh
git clone https://github.com/Drswith/codexpanel.git
cd codexpanel
open codexpanel.xcodeproj
```

Then:

1. Select your signing team in Xcode
2. Build and run the `codexpanel` target

Architecture and development references:

- [docs/development-isolation.md](./docs/development-isolation.md)
- [docs/architecture/core-ui-boundary.md](./docs/architecture/core-ui-boundary.md) (Core + UI boundary and migration contract)

## Release Process (Local Only)

This repository no longer uses GitHub Actions for release automation.  
Releases are now produced locally and uploaded to GitHub Releases manually.

- build dual-arch `Release` artifacts and assemble a universal app
- generate local `zip` / `dmg` and `sha256` files
- upload assets via `gh release upload` or `gh release create`

See:

- [docs/release-local.md](./docs/release-local.md)

## Acknowledgements

This project is based on and references the following projects:

- [lizhelang/codexbar](https://github.com/lizhelang/codexbar)
- [xmasdong/codexbar](https://github.com/xmasdong/codexbar)
- [steipete/CodexBar](https://github.com/steipete/CodexBar)

Detailed attribution is available in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).

## License

This repository is licensed under the Apache License, Version 2.0 by default. See [LICENSE](./LICENSE).

The upstream MIT license notice is preserved in [LICENSE.MIT](./LICENSE.MIT). Project origin, third-party attribution, and licensing boundaries are documented in [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).
