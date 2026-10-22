#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
BUILD_DIR="${CODEXPANEL_BUILD_DIR:-$ROOT_DIR/.build/macos}"
APP="$BUILD_DIR/Build/Products/Debug/Codex Panel DEV.app"
case "$MODE" in
  --build-only|--verify|--logs|--telemetry|--debug|run) ;;
  *) echo '用法: script/build_and_run.sh [run|--build-only|--verify|--logs|--telemetry|--debug]' >&2; exit 2 ;;
esac
# 仅结束本脚本构建的开发态进程，保留正式安装。
python3 - "$APP/Contents/MacOS/Codex Panel DEV" <<'PY'
import os, signal, subprocess, sys
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and os.path.realpath(parts[1]) == os.path.realpath(sys.argv[1]):
        os.kill(int(parts[0]), signal.SIGTERM)
PY
xcodebuild -project "$ROOT_DIR/codexpanel.xcodeproj" -scheme codexpanel \
  -configuration Debug -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath "$BUILD_DIR" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
if [[ "$MODE" == --build-only ]]; then exit 0; fi
/usr/bin/open -n "$APP" --env "CODEXPANEL_HOME=${CODEXPANEL_HOME:-$HOME/.codexpanel-dev/home}" --env "CODEXPANEL_DEBUG_MOCK_DATA=${CODEXPANEL_DEBUG_MOCK_DATA:-0}"
case "$MODE" in
  --logs|--telemetry)
    /usr/bin/log stream --info --style compact --predicate 'process == "Codex Panel DEV"' ;;
  --debug)
    APP_PID="$(python3 - "$APP/Contents/MacOS/Codex Panel DEV" <<'PYCODE'
import os, subprocess, sys
for line in subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines():
    parts = line.strip().split(None, 1)
    if len(parts) == 2 and os.path.realpath(parts[1]) == os.path.realpath(sys.argv[1]):
        print(parts[0]); break
else:
    raise SystemExit('未找到开发态进程')
PYCODE
)"
    xcrun lldb --attach-pid "$APP_PID" ;;
  --verify)
    python3 - "$APP/Contents/MacOS/Codex Panel DEV" <<'PY'
import os, subprocess, sys, time
for _ in range(50):
    rows = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    matches = [r.strip() for r in rows if os.path.realpath(r.strip().split(None, 1)[-1]) == os.path.realpath(sys.argv[1])]
    if matches:
        print('开发态进程已启动:', matches[0].split()[0]); break
    time.sleep(.1)
else:
    raise SystemExit('未找到开发态进程')
PY
    ;;
esac
