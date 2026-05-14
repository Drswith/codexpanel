#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/verify_release_artifacts.sh <universal-app-path> <dist-dir>
EOF
}

fail() {
  echo "$1" >&2
  exit 1
}

if [[ $# -ne 2 ]]; then
  usage >&2
  exit 2
fi

APP_PATH="$1"
DIST_DIR="$2"
MAIN_BINARY="$APP_PATH/Contents/MacOS/Codex Panel"
HELPER_BINARY="$APP_PATH/Contents/Helpers/codexpanel"
UPDATES_JSON="$DIST_DIR/updates.json"

[[ -f "$MAIN_BINARY" ]] || fail "App executable missing: $MAIN_BINARY"
[[ -f "$HELPER_BINARY" ]] || fail "Bundled CLI helper missing: $HELPER_BINARY"
[[ -x "$HELPER_BINARY" ]] || fail "Bundled CLI helper is not executable: $HELPER_BINARY"
[[ -f "$UPDATES_JSON" ]] || fail "updates.json missing: $UPDATES_JSON"

main_archs="$(lipo -archs "$MAIN_BINARY" 2>/dev/null || true)"
helper_archs="$(lipo -archs "$HELPER_BINARY" 2>/dev/null || true)"

[[ -n "$main_archs" ]] || fail "Unable to read app executable architectures: $MAIN_BINARY"
[[ -n "$helper_archs" ]] || fail "Unable to read helper architectures: $HELPER_BINARY"

for arch in $main_archs; do
  if [[ " $helper_archs " != *" $arch "* ]]; then
    fail "Bundled CLI helper missing architecture: $arch (helper archs: $helper_archs)"
  fi
done

extract_raw() {
  local key_path="$1"
  local output
  if output=$(/usr/bin/plutil -extract "$key_path" raw "$UPDATES_JSON" -o - 2>/dev/null); then
    printf '%s' "$output"
  else
    printf ''
  fi
}

require_non_null() {
  local value="$1"
  local key="$2"
  if [[ -z "$value" || "$value" == "null" ]]; then
    fail "updates.json missing $key"
  fi
}

version="$(extract_raw "release.version")"
require_non_null "$version" "release.version"

artifact0_format="$(extract_raw "release.artifacts.0.format")"
artifact1_format="$(extract_raw "release.artifacts.1.format")"
[[ "$artifact0_format" == "dmg" ]] || fail "updates.json expected release.artifacts.0.format=dmg"
[[ "$artifact1_format" == "zip" ]] || fail "updates.json expected release.artifacts.1.format=zip"

for index in 0 1; do
  download_url="$(extract_raw "release.artifacts.${index}.downloadURL")"
  sha256="$(extract_raw "release.artifacts.${index}.sha256")"
  require_non_null "$download_url" "release.artifacts.${index}.downloadURL"
  require_non_null "$sha256" "release.artifacts.${index}.sha256"
done
