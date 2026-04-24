# codexpanel 本地发版流程（无 GitHub Actions）

本仓库已移除 GitHub Actions 自动构建/自动发版。  
发版方式统一为：**本地打包后手动上传到 GitHub Release**。

## 快速命令（推荐）

可直接使用仓库脚本：

```sh
scripts/release_local.sh
```

上传到已存在 release：

```sh
scripts/release_local.sh --upload upload
```

创建 release 并上传：

```sh
scripts/release_local.sh --upload create --notes "Release 1.0.1"
```

默认会读取 `codexpanel.xcodeproj/project.pbxproj` 中的 `MARKETING_VERSION`。  
如果需要临时覆盖显示版本，再显式传 `--version x.y.z`。

## 0. 前置准备

- macOS + Xcode（命令行可用 `xcodebuild`）
- `gh` CLI 已登录（`gh auth status`）
- 已创建或准备创建目标 tag（例如 `v1.0.1`）

```sh
git fetch --tags
git checkout main
git pull --ff-only
```

## 1. 设置版本号

建议本次发版版本为 `VERSION=1.0.1`，tag 为 `TAG=v1.0.1`。

```sh
VERSION="1.0.1"
TAG="v${VERSION}"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
```

## 2. 本地构建双架构 Release 包

```sh
PROJECT="codexpanel.xcodeproj"
SCHEME="codexpanel"
APP_NAME="codexpanel.app"
APP_BASENAME="codexpanel"

WORK_DIR="$(pwd)/.release-tmp"
ARM64_DERIVED="$WORK_DIR/derived-arm64"
X64_DERIVED="$WORK_DIR/derived-x86_64"
UNIVERSAL_DIR="$WORK_DIR/universal"
DIST_DIR="$WORK_DIR/dist"

rm -rf "$WORK_DIR"
mkdir -p "$DIST_DIR" "$UNIVERSAL_DIR"

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
  build

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
  build
```

## 3. 合并成 universal `.app`

```sh
ARM64_APP="$ARM64_DERIVED/Build/Products/Release/$APP_NAME"
X64_APP="$X64_DERIVED/Build/Products/Release/$APP_NAME"
UNIVERSAL_APP="$UNIVERSAL_DIR/$APP_NAME"

cp -R "$ARM64_APP" "$UNIVERSAL_APP"

for binary in \
  "Contents/MacOS/codexpanel" \
  "Contents/MacOS/codexpanel.debug.dylib" \
  "Contents/MacOS/__preview.dylib"
do
  lipo -create \
    "$ARM64_APP/$binary" \
    "$X64_APP/$binary" \
    -output "$UNIVERSAL_APP/$binary"
done

file "$UNIVERSAL_APP/Contents/MacOS/codexpanel"
```

## 4. 可选：签名与公证

如果你走 Developer ID 分发，请先对 `UNIVERSAL_APP` 签名，再走 notarization。  
如果暂时是内测分发，可以跳过这一步。

## 5. 产出 zip + dmg

```sh
ZIP_NAME="${APP_BASENAME}-${VERSION}-macOS.zip"
DMG_NAME="${APP_BASENAME}-${VERSION}-macOS.dmg"

ditto -c -k --sequesterRsrc --keepParent "$UNIVERSAL_APP" "$DIST_DIR/$ZIP_NAME"

STAGING_DIR="$WORK_DIR/staging"
mkdir -p "$STAGING_DIR"
cp -R "$UNIVERSAL_APP" "$STAGING_DIR/$APP_NAME"

hdiutil create \
  -volname "codexpanel" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$DMG_NAME"

shasum -a 256 "$DIST_DIR/$ZIP_NAME" > "$DIST_DIR/$ZIP_NAME.sha256"
shasum -a 256 "$DIST_DIR/$DMG_NAME" > "$DIST_DIR/$DMG_NAME.sha256"
```

## 6. 上传 GitHub Release 资产

如果 tag 已存在 release：

```sh
gh release upload "$TAG" \
  "$DIST_DIR/$ZIP_NAME" \
  "$DIST_DIR/$ZIP_NAME.sha256" \
  "$DIST_DIR/$DMG_NAME" \
  "$DIST_DIR/$DMG_NAME.sha256" \
  --clobber
```

如果 tag 还没有 release，先创建再上传：

```sh
gh release create "$TAG" \
  "$DIST_DIR/$ZIP_NAME" \
  "$DIST_DIR/$ZIP_NAME.sha256" \
  "$DIST_DIR/$DMG_NAME" \
  "$DIST_DIR/$DMG_NAME.sha256" \
  --title "$TAG" \
  --notes "Release $VERSION"
```

## 7. 发版后核对

- GitHub release 页面存在 `dmg` 和 `zip` 资产
- `sha256` 文件与对应资产匹配
- 客户端“检查更新”可识别该正式 release
