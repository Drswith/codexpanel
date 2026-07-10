---
name: codexpanel-upstream-release
description: Execute codexpanel's selective upstream codexbar sync and mapped release workflow. Use when Codex must check lizhelang/codexbar for new versions, evaluate and port upstream changes version-by-version, update the internal upstream marker, run full Xcode validation, create and merge PRs, publish one codexpanel release per upstream version, sync docs/updates.json, verify release/update assets, run visual E2E on the latest source, or clean local macOS app/build residues after builds and releases.
---

# CodexPanel Upstream Release

## Non-Negotiables

- Work from `/Users/drs/workspaces/personal/codexpanel` unless the user explicitly changes the repo.
- Keep all collaboration text, commit messages, PR bodies, and release notes in Simplified Chinese.
- Treat `lizhelang/codexbar` as an unrelated-history upstream. Do not use normal merge mechanics unless a current `git merge-base` check proves otherwise.
- Sync upstream versions serially. One upstream version maps to one codexpanel version, one PR, one tag/release, and one update-source PR.
- Keep the development-only marker at `docs/development/codexbar-upstream-sync.json`. Do not make the app read it, show it, or package it intentionally. Preserve the marker's existing meaning for `mergedThroughCommit`; for annotated upstream tags, use the peeled commit for source diffs and record the tag object only when the marker already uses tag identity.
- Use the repo scripts for release packaging. Do not hand-roll DMG/ZIP/update feed generation when `scripts/release_local.sh` can do it.
- If GitHub direct HTTPS fails on this Mac, retry with `HTTPS_PROXY=http://127.0.0.1:7897 HTTP_PROXY=http://127.0.0.1:7897 ALL_PROXY=socks5h://127.0.0.1:7897`.
- Do not print OpenAI tokens or edit real `~/.codex` auth/config files. Debug builds must use the development profile or explicit temporary `CODEXPANEL_HOME`.
- After any local app build, release build, install, or packaging run, clean build/install residues and verify LaunchServices/Spotlight visibility.

## Discovery

1. Confirm state and baseline:
   ```bash
   git status --short --branch
   git fetch origin main --tags
   git log --oneline --decorate --max-count 8
   codegraph init -i
   cat docs/development/codexbar-upstream-sync.json
   ```
2. Check live upstream tags and `main`:
   ```bash
   git ls-remote --tags https://github.com/lizhelang/codexbar.git
   git ls-remote https://github.com/lizhelang/codexbar.git refs/heads/main
   git fetch https://github.com/lizhelang/codexbar.git main
   ```
3. Determine pending upstream tags by comparing the marker with live tags. Record untagged upstream `main` commits separately; do not mix them into a tag-mapped release unless the user asks.
4. Check whether the user supplied a codexpanel version mapping. If not, propose a consecutive patch mapping and wait only when the mapping would be risky.

## Per-Version Sync Loop

For each pending upstream tag, finish the whole loop before starting the next tag.

1. Create a scoped branch:
   ```bash
   git switch main
   git pull --ff-only origin main
   git switch -c codex/sync-codexbar-vX.Y.Z
   ```
2. Inspect upstream changes without blind merging:
   ```bash
   git show --stat --summary <upstream-tag-or-commit>
   git diff --stat <previous-upstream-commit>..<upstream-tag-or-commit>
   git diff <previous-upstream-commit>..<upstream-tag-or-commit> -- <relevant-paths>
   ```
   Search local source for equivalent symbols/files before porting; upstream improvements may already exist locally under different names.
3. Port only the relevant changes into codexpanel. Preserve local product boundaries, Debug/Release profile isolation, helper names, and existing architecture.
4. Update the mapped codexpanel version in `codexpanel.xcodeproj/project.pbxproj`.
5. Update `docs/development/codexbar-upstream-sync.json` to the exact upstream tag and the marker-compatible upstream object. Use peeled commits for source comparison even when the marker stores an annotated tag object.
6. Add or adjust focused tests for risky behavior, then run targeted tests when useful.
7. Run a full Xcode test before the PR:
   ```bash
   rm -rf /tmp/codexpanel-xcode-test.xcresult
   xcodebuild test \
     -project codexpanel.xcodeproj \
     -scheme codexpanel \
     -destination 'platform=macOS' \
     -resultBundlePath /tmp/codexpanel-xcode-test.xcresult
   xcrun xcresulttool get test-results summary --path /tmp/codexpanel-xcode-test.xcresult
   ```
8. Commit in Chinese, push, create a PR, wait for required checks, and merge through GitHub:
   ```bash
   git diff --check
   git add <changed-files>
   git commit -m "合入 codexbar vX.Y.Z"
   git push -u origin codex/sync-codexbar-vX.Y.Z
   gh pr create --base main --head codex/sync-codexbar-vX.Y.Z --title "合入 codexbar vX.Y.Z" --body "<Chinese summary and test evidence>"
   gh pr checks <pr-number> --watch --interval 10
   gh pr merge <pr-number> --squash --delete-branch --subject "合入 codexbar vX.Y.Z" --body "<Chinese merge body>"
   ```

## Release Loop

Run this immediately after each upstream sync PR merges.

1. Return to the merged `main`:
   ```bash
   git switch main
   git pull --ff-only origin main
   git status --short --branch
   ```
2. Publish the mapped codexpanel version with the repo script:
   ```bash
   scripts/release_local.sh \
     --version <codexpanel-version> \
     --no-commit \
     --tag \
     --push \
     --build \
     --upload create \
     --headless \
     --yes \
     --title "v<codexpanel-version>" \
     --notes "<Chinese release notes>"
   ```
3. Verify the release:
   ```bash
   gh release view v<codexpanel-version> --json tagName,name,isDraft,isPrerelease,url,assets
   shasum -a 256 -c .release-tmp/dist/codexpanel-<codexpanel-version>-macOS.zip.sha256 .release-tmp/dist/codexpanel-<codexpanel-version>-macOS.dmg.sha256
   gh api repos/Drswith/codexpanel/releases/latest --jq '.tag_name + " " + .html_url'
   curl --max-time 30 -fsSL https://github.com/Drswith/codexpanel/releases/latest/download/updates.json
   ```
   If `curl` fails but `gh` works, retry with the local proxy before calling the update chain broken.
4. Sync the generated update feed in a separate PR:
   ```bash
   git switch -c codex/sync-updates-v<codexpanel-version>
   cp .release-tmp/dist/updates.json docs/updates.json
   jq . docs/updates.json
   git diff -- docs/updates.json
   git add docs/updates.json
   git commit -m "docs(release): 同步 v<codexpanel-version> 更新源副本"
   git push -u origin codex/sync-updates-v<codexpanel-version>
   gh pr create --base main --head codex/sync-updates-v<codexpanel-version> --title "同步 v<codexpanel-version> 更新源副本" --body "<Chinese verification evidence>"
   gh pr checks <pr-number> --watch --interval 10
   gh pr merge <pr-number> --squash --delete-branch --subject "docs(release): 同步 v<codexpanel-version> 更新源副本" --body "<Chinese merge body>"
   ```

## Latest-Source Xcode And Visual E2E

Run this after the final mapped version is merged and released, or whenever the user asks for real latest-source validation.

1. Build and test from latest `main` with isolated output:
   ```bash
   git switch main
   git pull --ff-only origin main
   rm -rf /tmp/codexpanel-xcode-verify /tmp/codexpanel-xcode-verify-release /tmp/codexpanel-xcode-verify-test.xcresult /tmp/codexpanel-visual-e2e
   mkdir -p /tmp/codexpanel-visual-e2e

   xcodebuild -project codexpanel.xcodeproj -scheme codexpanel -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/codexpanel-xcode-verify -quiet build

   xcodebuild test -project codexpanel.xcodeproj -scheme codexpanel -destination 'platform=macOS' -derivedDataPath /tmp/codexpanel-xcode-verify -resultBundlePath /tmp/codexpanel-xcode-verify-test.xcresult -quiet
   xcrun xcresulttool get test-results summary --path /tmp/codexpanel-xcode-verify-test.xcresult

   xcodebuild -project codexpanel.xcodeproj -scheme codexpanel -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/codexpanel-xcode-verify-release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet build
   ```
2. Launch the Debug app with isolated home:
   ```bash
   APP="/tmp/codexpanel-xcode-verify/Build/Products/Debug/Codex Panel DEV.app"
   CLI="$APP/Contents/Helpers/codexpanel-dev"
   pkill -x "Codex Panel DEV" 2>/dev/null || true
   mkdir -p /tmp/codexpanel-visual-e2e/home
   launchctl setenv CODEXPANEL_HOME /tmp/codexpanel-visual-e2e/home
   /usr/bin/open -n "$APP"
   sleep 4
   launchctl unsetenv CODEXPANEL_HOME
   "$CLI" doctor --json
   "$CLI" state --json
   ```
3. Verify native routes and Accessibility snapshots:
   ```bash
   "$CLI" view open settings --page usage --wait 5 --json
   "$CLI" snapshot --format tree --target settings | tee /tmp/codexpanel-visual-e2e/settings-usage.tree.txt

   "$CLI" view close settings --wait 5 --json
   "$CLI" view open settings --page accounts --wait 5 --json
   "$CLI" snapshot --format tree --target settings | tee /tmp/codexpanel-visual-e2e/settings-accounts.tree.txt

   "$CLI" view close all --wait 5 --json
   "$CLI" view open menu --json
   sleep 2
   "$CLI" state --json

   "$CLI" view close all --wait 5 --json
   "$CLI" view open login --wait 5 --json
   "$CLI" snapshot --format tree --target all | tee /tmp/codexpanel-visual-e2e/login-all.tree.txt
   ```
4. Capture real screenshots when AX state is incomplete. Use `swift`/CoreGraphics to list `Codex Panel DEV` window IDs, then:
   ```bash
   screencapture -x -l <window-id> /tmp/codexpanel-visual-e2e/<surface>.png
   sips -g pixelWidth -g pixelHeight /tmp/codexpanel-visual-e2e/<surface>.png
   ```
5. Treat discrepancies between visible windows and CLI state as E2E findings. Known surfaces to distinguish:
   - `view open settings --page <page>` may return success while an already-open settings window does not switch pages; close and reopen to verify the target page itself.
   - `view open menu --wait` may time out even when the menu popover visibly opens; confirm with screenshot and CoreGraphics window listing.
   - `snapshot --target login` may be less complete than `snapshot --target all`; use `target all` to verify the login window tree.

## Cleanup

Always clean after build/release/E2E work:

```bash
if [[ -n "${CLI:-}" && -x "$CLI" ]]; then
  "$CLI" view close all --wait 5 --json || true
fi
pkill -x "Codex Panel DEV" 2>/dev/null || true

for root in /tmp/codexpanel-xcode-verify /tmp/codexpanel-xcode-verify-release .release-tmp; do
  if [[ -d "$root" ]]; then
    find "$root" -name '*.app' -type d -prune -print | while read -r app; do
      /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" || true
    done
  fi
done

rm -rf /tmp/codexpanel-xcode-verify /tmp/codexpanel-xcode-verify-release /tmp/codexpanel-xcode-verify-test.xcresult .release-tmp
scripts/check_update_readiness.sh "/Applications/Codex Panel.app"
git status --short --branch
```

Do not delete user-kept DMGs, archives, backups, or non-temporary app copies without explicit user approval.

## Final Report

Report compactly:

- Upstream tag to codexpanel version mapping.
- PR URLs and merge status for each sync PR and update-source PR.
- Release URLs and asset completeness for each codexpanel version.
- Full Xcode test counts from `.xcresult`.
- Visual E2E surfaces inspected, screenshot paths, and any real UI/driver findings.
- Current marker contents and any upstream untagged commits left out of the mapped releases.
- Cleanup result, including LaunchServices/Spotlight visibility and remaining known non-temporary app copies.
