#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/release_local.sh [options]

Options:
  --version <x.y.z>         Optional override for marketing version, e.g. 1.0.1
                            Default: read MARKETING_VERSION from project.pbxproj
  --tag <tag>               Release tag. Default: v<version>
  --build-number <value>    Build number. Default: YYYYMMDDHHMM
  --project <path>          Xcode project. Default: codexpanel.xcodeproj
  --scheme <name>           Xcode scheme. Default: codexpanel
  --app-name <name>         App bundle name. Default: codexpanel.app
  --app-basename <name>     Artifact base name. Default: codexpanel
  --work-dir <path>         Build working dir. Default: .release-tmp
  --upload none|upload|create
                            none   -> do not upload (default)
                            upload -> upload to existing release tag
                            create -> create release then upload assets
  --title <text>            Release title (for --upload=create). Default: <tag>
  --notes <text>            Release notes (for --upload=create). Default: Release <version>
  --help                    Show this help

Examples:
  scripts/release_local.sh
  scripts/release_local.sh --version 1.0.1
  scripts/release_local.sh --version 1.0.1 --upload upload
  scripts/release_local.sh --version 1.0.1 --upload create --notes "Release 1.0.1"
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

VERSION=""
TAG=""
BUILD_NUMBER=""
PROJECT="codexpanel.xcodeproj"
SCHEME="codexpanel"
APP_NAME="codexpanel.app"
APP_BASENAME="codexpanel"
WORK_DIR=""
UPLOAD_MODE="none"
RELEASE_TITLE=""
RELEASE_NOTES=""

resolve_default_version() {
  local pbxproj="${PROJECT}/project.pbxproj"
  if [[ ! -f "$pbxproj" ]]; then
    return 1
  fi

  awk -F ' = ' '/MARKETING_VERSION = / { gsub(/;/, "", $2); print $2; exit }' "$pbxproj"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"
      shift 2
      ;;
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="${2:-}"
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
      shift 2
      ;;
    --app-basename)
      APP_BASENAME="${2:-}"
      shift 2
      ;;
    --work-dir)
      WORK_DIR="${2:-}"
      shift 2
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

if [[ -z "$VERSION" ]]; then
  VERSION="$(resolve_default_version || true)"
fi

if [[ -z "$VERSION" ]]; then
  echo "Unable to resolve MARKETING_VERSION from $PROJECT/project.pbxproj; pass --version explicitly." >&2
  usage
  exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
  echo "Invalid --version: $VERSION" >&2
  exit 1
fi

if [[ -z "$TAG" ]]; then
  TAG="v$VERSION"
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
  RELEASE_NOTES="Release $VERSION"
fi

if [[ "$UPLOAD_MODE" != "none" && "$UPLOAD_MODE" != "upload" && "$UPLOAD_MODE" != "create" ]]; then
  echo "Invalid --upload mode: $UPLOAD_MODE" >&2
  exit 1
fi

require_cmd xcodebuild
require_cmd lipo
require_cmd ditto
require_cmd hdiutil
require_cmd shasum
if [[ "$UPLOAD_MODE" != "none" ]]; then
  require_cmd gh
fi

ARM64_DERIVED="$WORK_DIR/derived-arm64"
X64_DERIVED="$WORK_DIR/derived-x86_64"
UNIVERSAL_DIR="$WORK_DIR/universal"
DIST_DIR="$WORK_DIR/dist"
STAGING_DIR="$WORK_DIR/staging"

ZIP_NAME="${APP_BASENAME}-${VERSION}-macOS.zip"
DMG_NAME="${APP_BASENAME}-${VERSION}-macOS.dmg"

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
  MARKETING_VERSION="$VERSION" \
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
  MARKETING_VERSION="$VERSION" \
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
  "Contents/MacOS/codexpanel" \
  "Contents/MacOS/codexpanel.debug.dylib" \
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
cp -R "$UNIVERSAL_APP" "$STAGING_DIR/$APP_NAME"
hdiutil create \
  -volname "codexpanel" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

shasum -a 256 "$DIST_DIR/$ZIP_NAME" > "$DIST_DIR/$ZIP_NAME.sha256"
shasum -a 256 "$DIST_DIR/$DMG_NAME" > "$DIST_DIR/$DMG_NAME.sha256"

if [[ "$UPLOAD_MODE" == "upload" ]]; then
  echo "==> Uploading assets to existing release: $TAG"
  gh release upload "$TAG" \
    "$DIST_DIR/$ZIP_NAME" \
    "$DIST_DIR/$ZIP_NAME.sha256" \
    "$DIST_DIR/$DMG_NAME" \
    "$DIST_DIR/$DMG_NAME.sha256" \
    --clobber
elif [[ "$UPLOAD_MODE" == "create" ]]; then
  echo "==> Creating release and uploading assets: $TAG"
  gh release create "$TAG" \
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
echo
echo "Done."
