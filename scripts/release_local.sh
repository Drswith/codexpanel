#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release_local.sh [release] [options]

Release (optional):
  major | minor | patch | beta | alpha | rc | prerelease | premajor | preminor | prepatch
  Example: scripts/release_local.sh minor

Options:
  --release <type>          Release type (same as positional release)
  --version <x.y.z[-pre.n]> Override target version directly
  --preid <id>              Pre-release identifier. Default: beta
  --project <path>          Xcode project. Default: codexpanel.xcodeproj
  --scheme <name>           Xcode scheme. Default: codexpanel
  --app-name <name>         App bundle name. Default: Codex Panel.app
  --app-basename <name>     Artifact base name. Default: codexpanel
  --build-number <value>    Build number. Default: YYYYMMDDHHMM
  --work-dir <path>         Build working dir. Default: .release-tmp

  --commit / --no-commit    Commit version bump. Default: commit
  --tag / --no-tag          Create git tag. Default: tag
  --push / --no-push        Push commit/tag. Default: push
  --tag-prefix <prefix>     Tag prefix. Default: v
  --commit-message <msg>    Commit message. Default: chore(release): v<version>
  --allow-dirty             Allow git operations on a dirty worktree
  --yes                     Skip confirmation prompt
  --dry-run                 Print planned operations without changing files/git
  --interactive             Force interactive prompts
  --headless                Disable interactive prompts

  --build / --no-build      Build and package artifacts. Default: build
  --upload none|upload|create
                            none   -> do not upload (default)
                            upload -> upload to existing release tag
                            create -> create release then upload assets
  --title <text>            Release title (for --upload=create). Default: <tag>
  --notes <text>            Release notes (for --upload=create). Default: Release <version>

  --help                    Show this help

Examples:
  scripts/release_local.sh minor
  scripts/release_local.sh beta --preid beta --no-build
  scripts/release_local.sh --version 1.2.0 --no-push
  scripts/release_local.sh patch --upload create --yes
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

prepare_dmg_staging_dir() {
  local app_path="$1"
  local staging_dir="$2"
  local app_name="$3"
  local include_background="$4"
  local background_asset="$5"

  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"
  cp -R "$app_path" "$staging_dir/$app_name"
  ln -s /Applications "$staging_dir/Applications"

  if [[ "$include_background" == "true" ]]; then
    local background_dir="$staging_dir/.background"
    local background_path="$background_dir/background.png"
    mkdir -p "$background_dir"
    cp "$background_asset" "$background_path"
  fi
}

create_plain_dmg() {
  local staging_dir="$1"
  local output_path="$2"
  local volume_name="$3"

  hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDZO \
    "$output_path"
}

create_installer_dmg() {
  local staging_dir="$1"
  local output_path="$2"
  local volume_name="$3"
  local app_name="$4"
  local applescript_path="$5"
  local temp_dmg="$6"
  local attach_output=""
  local attached_device=""
  local attached_mount_point=""
  local mounted_volume_name=""
  local customize_failed="false"

  rm -f "$temp_dmg" "$output_path"

  hdiutil create \
    -volname "$volume_name" \
    -srcfolder "$staging_dir" \
    -ov \
    -format UDRW \
    "$temp_dmg"

  attach_output="$(
    hdiutil attach \
      -readwrite \
      -noverify \
      -noautoopen \
      "$temp_dmg"
  )"

  attached_device="$(
    printf '%s\n' "$attach_output" | awk -F '\t' '/^\/dev\/disk/ { print $1; exit }'
  )"
  attached_mount_point="$(
    printf '%s\n' "$attach_output" | awk -F '\t' '/^\/dev\/disk/ && $NF ~ /^\/Volumes\// { mount=$NF } END { print mount }'
  )"
  mounted_volume_name="$(basename "$attached_mount_point")"

  if [[ -z "$attached_device" || -z "$attached_mount_point" || -z "$mounted_volume_name" ]]; then
    echo "Unable to determine mounted DMG device or mount point." >&2
    rm -f "$temp_dmg"
    exit 1
  fi

  if ! osascript "$applescript_path" "$mounted_volume_name" "$app_name"; then
    customize_failed="true"
    echo "Warning: Finder 布局定制失败，将回退到普通 DMG。" >&2
  fi

  sync

  if ! hdiutil detach "$attached_device" >/dev/null 2>&1; then
    sleep 2
    if [[ -e "$attached_mount_point" ]]; then
      hdiutil detach "$attached_mount_point" -force >/dev/null 2>&1 || true
    else
      hdiutil detach "$attached_device" -force >/dev/null 2>&1 || true
    fi
  fi

  if [[ "$customize_failed" == "true" ]]; then
    rm -f "$temp_dmg"
    create_plain_dmg "$staging_dir" "$output_path" "$volume_name"
    return
  fi

  hdiutil convert \
    "$temp_dmg" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "$output_path"

  rm -f "$temp_dmg"
}

is_valid_semver() {
  local v="$1"
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]
}

resolve_default_version() {
  local pbxproj="${PROJECT}/project.pbxproj"
  [[ -f "$pbxproj" ]] || return 1
  awk -F ' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$pbxproj"
}

split_semver() {
  local version="$1"
  local core="${version%%-*}"
  local pre=""
  if [[ "$version" == *-* ]]; then
    pre="${version#*-}"
  fi

  IFS='.' read -r SEMVER_MAJOR SEMVER_MINOR SEMVER_PATCH <<<"$core"
  SEMVER_PRE="$pre"
}

next_prerelease() {
  local base="$1"
  local preid="$2"
  local current="$3"

  if [[ -n "$current" ]]; then
    if [[ "$current" =~ ^${preid}\.([0-9]+)$ ]]; then
      local n="${BASH_REMATCH[1]}"
      echo "${base}-${preid}.$((n + 1))"
      return 0
    fi
  fi

  echo "${base}-${preid}.0"
}

bump_version() {
  local current="$1"
  local release="$2"
  local preid="$3"
  split_semver "$current"

  local major="$SEMVER_MAJOR"
  local minor="$SEMVER_MINOR"
  local patch="$SEMVER_PATCH"
  local pre="$SEMVER_PRE"
  local base=""

  case "$release" in
    major)
      echo "$((major + 1)).0.0"
      ;;
    minor)
      echo "${major}.$((minor + 1)).0"
      ;;
    patch)
      echo "${major}.${minor}.$((patch + 1))"
      ;;
    prerelease)
      base="${major}.${minor}.${patch}"
      next_prerelease "$base" "$preid" "$pre"
      ;;
    premajor)
      base="$((major + 1)).0.0"
      next_prerelease "$base" "$preid" ""
      ;;
    preminor)
      base="${major}.$((minor + 1)).0"
      next_prerelease "$base" "$preid" ""
      ;;
    prepatch)
      base="${major}.${minor}.$((patch + 1))"
      next_prerelease "$base" "$preid" ""
      ;;
    beta|alpha|rc)
      if [[ -n "$pre" && "$pre" =~ ^${release}\.([0-9]+)$ ]]; then
        base="${major}.${minor}.${patch}"
        next_prerelease "$base" "$release" "$pre"
      elif [[ -n "$pre" ]]; then
        base="${major}.${minor}.${patch}"
        next_prerelease "$base" "$release" ""
      else
        base="${major}.${minor}.$((patch + 1))"
        next_prerelease "$base" "$release" ""
      fi
      ;;
    *)
      echo "Unsupported release type: $release" >&2
      return 1
      ;;
  esac
}

update_marketing_version() {
  local pbxproj="${PROJECT}/project.pbxproj"
  [[ -f "$pbxproj" ]] || {
    echo "Missing pbxproj: $pbxproj" >&2
    exit 1
  }

  perl -i -pe "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = ${TARGET_VERSION};/g" "$pbxproj"
}

git_worktree_dirty() {
  ! git diff --quiet || ! git diff --cached --quiet
}

PROJECT="codexpanel.xcodeproj"
SCHEME="codexpanel"
APP_NAME="Codex Panel.app"
APP_BASENAME="codexpanel"
APP_EXECUTABLE_NAME="${APP_NAME%.app}"
WORK_DIR=""
BUILD_NUMBER=""
PREID="beta"

RELEASE_TYPE=""
TARGET_VERSION=""
POSITIONAL_RELEASE=""

DO_COMMIT="true"
DO_TAG="true"
DO_PUSH="true"
TAG_PREFIX="v"
COMMIT_MESSAGE=""
ALLOW_DIRTY="false"
ASSUME_YES="false"
DRY_RUN="false"
FORCE_INTERACTIVE="false"
FORCE_HEADLESS="false"

DO_BUILD="true"
UPLOAD_MODE="none"
RELEASE_TITLE=""
RELEASE_NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    major|minor|patch|beta|alpha|rc|prerelease|premajor|preminor|prepatch)
      POSITIONAL_RELEASE="$1"
      shift
      ;;
    --release)
      RELEASE_TYPE="${2:-}"
      shift 2
      ;;
    --version)
      TARGET_VERSION="${2:-}"
      shift 2
      ;;
    --preid)
      PREID="${2:-}"
      shift 2
      ;;
    --project)
      PROJECT="${2:-}"
      shift 2
      ;;
    --scheme)
      SCHEME="${2:-}"
      shift 2
      ;;
    --app-name)
      APP_NAME="${2:-}"
      APP_EXECUTABLE_NAME="${APP_NAME%.app}"
      shift 2
      ;;
    --app-basename)
      APP_BASENAME="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="${2:-}"
      shift 2
      ;;
    --commit)
      DO_COMMIT="true"
      shift
      ;;
    --no-commit)
      DO_COMMIT="false"
      shift
      ;;
    --tag)
      DO_TAG="true"
      shift
      ;;
    --no-tag)
      DO_TAG="false"
      shift
      ;;
    --push)
      DO_PUSH="true"
      shift
      ;;
    --no-push)
      DO_PUSH="false"
      shift
      ;;
    --tag-prefix)
      TAG_PREFIX="${2:-}"
      shift 2
      ;;
    --commit-message)
      COMMIT_MESSAGE="${2:-}"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY="true"
      shift
      ;;
    --yes|-y)
      ASSUME_YES="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --interactive)
      FORCE_INTERACTIVE="true"
      shift
      ;;
    --headless)
      FORCE_HEADLESS="true"
      shift
      ;;
    --build)
      DO_BUILD="true"
      shift
      ;;
    --no-build)
      DO_BUILD="false"
      shift
      ;;
    --upload)
      UPLOAD_MODE="${2:-}"
      shift 2
      ;;
    --title)
      RELEASE_TITLE="${2:-}"
      shift 2
      ;;
    --notes)
      RELEASE_NOTES="${2:-}"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$FORCE_INTERACTIVE" == "true" && "$FORCE_HEADLESS" == "true" ]]; then
  echo "--interactive and --headless cannot be used together." >&2
  exit 1
fi

if [[ -n "$POSITIONAL_RELEASE" && -n "$RELEASE_TYPE" ]]; then
  echo "Use either positional release or --release, not both." >&2
  exit 1
fi
if [[ -n "$POSITIONAL_RELEASE" ]]; then
  RELEASE_TYPE="$POSITIONAL_RELEASE"
fi

CURRENT_VERSION="$(resolve_default_version || true)"
if [[ -z "$CURRENT_VERSION" ]]; then
  echo "Unable to resolve MARKETING_VERSION from $PROJECT/project.pbxproj" >&2
  exit 1
fi

if [[ -n "$TARGET_VERSION" && -n "$RELEASE_TYPE" ]]; then
  echo "Use either --version or release type, not both." >&2
  exit 1
fi

if [[ -z "$TARGET_VERSION" && -n "$RELEASE_TYPE" ]]; then
  TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "$RELEASE_TYPE" "$PREID")"
fi

INTERACTIVE_MODE="false"
if [[ "$FORCE_INTERACTIVE" == "true" ]]; then
  INTERACTIVE_MODE="true"
elif [[ "$FORCE_HEADLESS" == "true" ]]; then
  INTERACTIVE_MODE="false"
elif [[ -t 0 && -z "$TARGET_VERSION" && -z "$RELEASE_TYPE" ]]; then
  INTERACTIVE_MODE="true"
fi

if [[ "$INTERACTIVE_MODE" == "true" ]]; then
  echo "Interactive release mode"
  echo "Current version: $CURRENT_VERSION"
  echo
  local_choices=(
    "patch"
    "minor"
    "major"
    "beta"
    "alpha"
    "rc"
    "custom"
    "keep"
  )

  echo "Select release type:"
  echo "  1) patch  -> $(bump_version "$CURRENT_VERSION" "patch" "$PREID")"
  echo "  2) minor  -> $(bump_version "$CURRENT_VERSION" "minor" "$PREID")"
  echo "  3) major  -> $(bump_version "$CURRENT_VERSION" "major" "$PREID")"
  echo "  4) beta   -> $(bump_version "$CURRENT_VERSION" "beta" "beta")"
  echo "  5) alpha  -> $(bump_version "$CURRENT_VERSION" "alpha" "alpha")"
  echo "  6) rc     -> $(bump_version "$CURRENT_VERSION" "rc" "rc")"
  echo "  7) custom version"
  echo "  8) keep current version"
  read -r -p "Choice [1-8]: " release_choice

  case "$release_choice" in
    1) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "patch" "$PREID")" ;;
    2) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "minor" "$PREID")" ;;
    3) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "major" "$PREID")" ;;
    4) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "beta" "beta")" ;;
    5) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "alpha" "alpha")" ;;
    6) TARGET_VERSION="$(bump_version "$CURRENT_VERSION" "rc" "rc")" ;;
    7)
      read -r -p "Enter version (e.g. 1.2.3 or 1.2.3-beta.0): " TARGET_VERSION
      ;;
    8) TARGET_VERSION="$CURRENT_VERSION" ;;
    *)
      echo "Invalid choice." >&2
      exit 1
      ;;
  esac

  read -r -p "Commit version bump? [Y/n]: " answer_commit
  if [[ "$answer_commit" == "n" || "$answer_commit" == "N" ]]; then
    DO_COMMIT="false"
  else
    DO_COMMIT="true"
  fi

  read -r -p "Create git tag? [Y/n]: " answer_tag
  if [[ "$answer_tag" == "n" || "$answer_tag" == "N" ]]; then
    DO_TAG="false"
  else
    DO_TAG="true"
  fi

  read -r -p "Push commit/tag? [Y/n]: " answer_push
  if [[ "$answer_push" == "n" || "$answer_push" == "N" ]]; then
    DO_PUSH="false"
  else
    DO_PUSH="true"
  fi

  read -r -p "Build release artifacts? [Y/n]: " answer_build
  if [[ "$answer_build" == "n" || "$answer_build" == "N" ]]; then
    DO_BUILD="false"
  else
    DO_BUILD="true"
  fi

  if [[ "$DO_BUILD" == "true" ]]; then
    echo "Upload mode:"
    echo "  1) none"
    echo "  2) upload (existing tag)"
    echo "  3) create (new release)"
    read -r -p "Choice [1-3]: " upload_choice
    case "$upload_choice" in
      1|"") UPLOAD_MODE="none" ;;
      2) UPLOAD_MODE="upload" ;;
      3) UPLOAD_MODE="create" ;;
      *)
        echo "Invalid upload choice." >&2
        exit 1
        ;;
    esac
  else
    UPLOAD_MODE="none"
  fi
fi

if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="$CURRENT_VERSION"
fi

if ! is_valid_semver "$TARGET_VERSION"; then
  echo "Invalid target version: $TARGET_VERSION" >&2
  exit 1
fi

TAG="${TAG_PREFIX}${TARGET_VERSION}"
if [[ -z "$COMMIT_MESSAGE" ]]; then
  COMMIT_MESSAGE="chore(release): ${TAG}"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(date +%Y%m%d%H%M)"
fi
if [[ -z "$WORK_DIR" ]]; then
  WORK_DIR="$(pwd)/.release-tmp"
fi
if [[ -z "$RELEASE_TITLE" ]]; then
  RELEASE_TITLE="$TAG"
fi
if [[ -z "$RELEASE_NOTES" ]]; then
  RELEASE_NOTES="Release $TARGET_VERSION"
fi

if [[ "$UPLOAD_MODE" != "none" && "$UPLOAD_MODE" != "upload" && "$UPLOAD_MODE" != "create" ]]; then
  echo "Invalid --upload mode: $UPLOAD_MODE" >&2
  exit 1
fi
if [[ "$UPLOAD_MODE" != "none" && "$DO_BUILD" != "true" ]]; then
  echo "--upload requires build step. Remove --no-build or set --upload none." >&2
  exit 1
fi

if [[ "$DO_PUSH" == "true" && "$DO_COMMIT" == "false" && "$DO_TAG" == "false" ]]; then
  echo "--push has nothing to push when both --no-commit and --no-tag are set." >&2
  exit 1
fi

if [[ "$DO_TAG" == "true" && "$DO_COMMIT" == "false" && "$ALLOW_DIRTY" != "true" ]] && git_worktree_dirty; then
  echo "Dirty worktree detected. Use --allow-dirty if you really want to tag without committing." >&2
  exit 1
fi

if [[ "$DO_COMMIT" == "true" && "$ALLOW_DIRTY" != "true" ]] && git_worktree_dirty; then
  echo "Dirty worktree detected. Commit or stash existing changes first, or pass --allow-dirty." >&2
  exit 1
fi

if [[ "$DO_BUILD" == "true" ]]; then
  require_cmd xcodebuild
  require_cmd lipo
  require_cmd ditto
  require_cmd hdiutil
  require_cmd shasum
  require_cmd swift
fi
if [[ "$DO_PUSH" == "true" || "$DO_TAG" == "true" || "$DO_COMMIT" == "true" || "$UPLOAD_MODE" != "none" ]]; then
  require_cmd git
fi
if [[ "$UPLOAD_MODE" != "none" ]]; then
  require_cmd gh
fi

echo "Current version: $CURRENT_VERSION"
echo "Target version:  $TARGET_VERSION"
echo "Tag:             $TAG"
echo "Commit:          $DO_COMMIT"
echo "Tag create:      $DO_TAG"
echo "Push:            $DO_PUSH"
echo "Build package:   $DO_BUILD"
echo "Upload mode:     $UPLOAD_MODE"
echo

if [[ "$ASSUME_YES" != "true" && -t 0 ]]; then
  read -r -p "Continue? [y/N] " confirm
  if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

if [[ "$DRY_RUN" == "true" ]]; then
  echo "[dry-run] No files or git state were changed."
  exit 0
fi

if [[ "$TARGET_VERSION" != "$CURRENT_VERSION" ]]; then
  echo "==> Updating MARKETING_VERSION in $PROJECT/project.pbxproj"
  update_marketing_version
else
  echo "==> Version unchanged; skip MARKETING_VERSION update"
fi

if [[ "$DO_COMMIT" == "true" ]]; then
  echo "==> Committing version changes"
  git add "$PROJECT/project.pbxproj"
  if git diff --cached --quiet; then
    echo "No staged changes for commit; skip commit."
    DO_COMMIT="false"
  else
    git commit -m "$COMMIT_MESSAGE"
  fi
fi

if [[ "$DO_TAG" == "true" ]]; then
  echo "==> Creating tag: $TAG"
  if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "Tag already exists: $TAG" >&2
    exit 1
  fi
  git tag -a "$TAG" -m "$TAG"
fi

if [[ "$DO_PUSH" == "true" ]]; then
  echo "==> Pushing to remote"
  if [[ "$DO_COMMIT" == "true" && "$DO_TAG" == "true" ]]; then
    git push --follow-tags
  elif [[ "$DO_COMMIT" == "true" ]]; then
    git push
  elif [[ "$DO_TAG" == "true" ]]; then
    git push origin "$TAG"
  fi
fi

if [[ "$DO_BUILD" != "true" ]]; then
  echo "==> Build skipped (--no-build)"
  exit 0
fi

ARM64_DERIVED="$WORK_DIR/derived-arm64"
X64_DERIVED="$WORK_DIR/derived-x86_64"
UNIVERSAL_DIR="$WORK_DIR/universal"
DIST_DIR="$WORK_DIR/dist"
STAGING_DIR="$WORK_DIR/staging"
ZIP_NAME="${APP_BASENAME}-${TARGET_VERSION}-macOS.zip"
DMG_NAME="${APP_BASENAME}-${TARGET_VERSION}-macOS.dmg"
DMG_RW_NAME="${APP_BASENAME}-${TARGET_VERSION}-macOS-temp.dmg"
DMG_VOLUME_NAME="codexpanel"
DMG_BACKGROUND_ASSET="$(pwd)/scripts/assets/dmg-background.png"
DMG_LAYOUT_SCRIPT="$(pwd)/scripts/customize_dmg_layout.applescript"
UPDATES_JSON_NAME="updates.json"
UPDATES_JSON_PATH="$DIST_DIR/$UPDATES_JSON_NAME"
RELEASE_URL="https://github.com/Drswith/codexpanel/releases/tag/$TAG"
DOWNLOAD_ROOT="https://github.com/Drswith/codexpanel/releases/download/$TAG"

echo "==> Preparing workspace"
rm -rf "$WORK_DIR"
mkdir -p "$DIST_DIR" "$UNIVERSAL_DIR" "$STAGING_DIR"

echo "==> Building arm64 release"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$ARM64_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$TARGET_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  SWIFT_COMPILATION_MODE=singlefile \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  build

echo "==> Building x86_64 release"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS,arch=x86_64" \
  -derivedDataPath "$X64_DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$TARGET_VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=x86_64 \
  SWIFT_COMPILATION_MODE=singlefile \
  SWIFT_OPTIMIZATION_LEVEL=-Onone \
  build

ARM64_APP="$ARM64_DERIVED/Build/Products/Release/$APP_NAME"
X64_APP="$X64_DERIVED/Build/Products/Release/$APP_NAME"
UNIVERSAL_APP="$UNIVERSAL_DIR/$APP_NAME"

if [[ ! -d "$ARM64_APP" || ! -d "$X64_APP" ]]; then
  echo "Missing architecture app output(s)." >&2
  exit 1
fi

echo "==> Assembling universal app"
cp -R "$ARM64_APP" "$UNIVERSAL_APP"
for binary in \
  "Contents/MacOS/$APP_EXECUTABLE_NAME" \
  "Contents/MacOS/$APP_EXECUTABLE_NAME.debug.dylib" \
  "Contents/MacOS/__preview.dylib"
do
  if [[ ! -f "$ARM64_APP/$binary" || ! -f "$X64_APP/$binary" ]]; then
    echo "Missing binary for lipo: $binary" >&2
    exit 1
  fi
  lipo -create \
    "$ARM64_APP/$binary" \
    "$X64_APP/$binary" \
    -output "$UNIVERSAL_APP/$binary"
done

echo "==> Packaging artifacts"
ditto -c -k --sequesterRsrc --keepParent "$UNIVERSAL_APP" "$DIST_DIR/$ZIP_NAME"
prepare_dmg_staging_dir \
  "$UNIVERSAL_APP" \
  "$STAGING_DIR" \
  "$APP_NAME" \
  "$([[ "$FORCE_HEADLESS" == "true" ]] && echo "false" || echo "true")" \
  "$DMG_BACKGROUND_ASSET"

if [[ "$FORCE_HEADLESS" == "true" ]]; then
  echo "==> Headless 模式：生成带 Applications 快捷方式的普通 DMG"
  create_plain_dmg \
    "$STAGING_DIR" \
    "$DIST_DIR/$DMG_NAME" \
    "$DMG_VOLUME_NAME"
else
  echo "==> 生成带背景与拖拽引导的安装型 DMG"
  create_installer_dmg \
    "$STAGING_DIR" \
    "$DIST_DIR/$DMG_NAME" \
    "$DMG_VOLUME_NAME" \
    "$APP_NAME" \
    "$DMG_LAYOUT_SCRIPT" \
    "$WORK_DIR/$DMG_RW_NAME"
fi

shasum -a 256 "$DIST_DIR/$ZIP_NAME" > "$DIST_DIR/$ZIP_NAME.sha256"
shasum -a 256 "$DIST_DIR/$DMG_NAME" > "$DIST_DIR/$DMG_NAME.sha256"

ZIP_SHA256="$(awk '{print $1}' "$DIST_DIR/$ZIP_NAME.sha256")"
DMG_SHA256="$(awk '{print $1}' "$DIST_DIR/$DMG_NAME.sha256")"
PUBLISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

cat > "$UPDATES_JSON_PATH" <<EOF
{
  "schemaVersion": 1,
  "channel": "stable",
  "release": {
    "version": "$TARGET_VERSION",
    "publishedAt": "$PUBLISHED_AT",
    "summary": "$TAG",
    "releaseNotesURL": "$RELEASE_URL",
    "downloadPageURL": "$RELEASE_URL",
    "deliveryMode": "guidedDownload",
    "minimumAutomaticUpdateVersion": null,
    "artifacts": [
      {
        "architecture": "universal",
        "format": "dmg",
        "downloadURL": "$DOWNLOAD_ROOT/$DMG_NAME",
        "sha256": "$DMG_SHA256"
      },
      {
        "architecture": "universal",
        "format": "zip",
        "downloadURL": "$DOWNLOAD_ROOT/$ZIP_NAME",
        "sha256": "$ZIP_SHA256"
      }
    ]
  }
}
EOF

if [[ "$UPLOAD_MODE" == "upload" ]]; then
  echo "==> Uploading assets to existing release: $TAG"
  gh release upload "$TAG" \
    "$UPDATES_JSON_PATH" \
    "$DIST_DIR/$ZIP_NAME" \
    "$DIST_DIR/$ZIP_NAME.sha256" \
    "$DIST_DIR/$DMG_NAME" \
    "$DIST_DIR/$DMG_NAME.sha256" \
    --clobber
elif [[ "$UPLOAD_MODE" == "create" ]]; then
  echo "==> Creating release and uploading assets: $TAG"
  gh release create "$TAG" \
    "$UPDATES_JSON_PATH" \
    "$DIST_DIR/$ZIP_NAME" \
    "$DIST_DIR/$ZIP_NAME.sha256" \
    "$DIST_DIR/$DMG_NAME" \
    "$DIST_DIR/$DMG_NAME.sha256" \
    --title "$RELEASE_TITLE" \
    --notes "$RELEASE_NOTES"
fi

echo
echo "Release artifacts are ready:"
echo "  ZIP: $DIST_DIR/$ZIP_NAME"
echo "  ZIP SHA256: $DIST_DIR/$ZIP_NAME.sha256"
echo "  DMG: $DIST_DIR/$DMG_NAME"
echo "  DMG SHA256: $DIST_DIR/$DMG_NAME.sha256"
echo "  Update feed template: $UPDATES_JSON_PATH"
echo
echo "Next step:"
echo "  cp \"$UPDATES_JSON_PATH\" \"$(pwd)/docs/updates.json\""
echo
echo "Done."
