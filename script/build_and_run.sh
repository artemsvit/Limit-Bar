#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
case "$MODE" in
  run|--debug|--logs|--telemetry|--verify) ;;
  *) echo "Usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
pkill -x 'Limit Bar' >/dev/null 2>&1 || true
xcodebuild -project 'Limit Bar.xcodeproj' -scheme 'Limit Bar' \
  -configuration Debug -derivedDataPath "$ROOT_DIR/build/Development" build

APP_PATH="$ROOT_DIR/build/Development/Build/Products/Debug/Limit Bar.app"
if [[ "$MODE" == --debug ]]; then
  exec lldb -- "$APP_PATH/Contents/MacOS/Limit Bar"
fi
/usr/bin/open -n "$APP_PATH"
case "$MODE" in
  --verify) sleep 1; pgrep -x 'Limit Bar' >/dev/null ;;
  --logs|--telemetry)
    exec /usr/bin/log stream --info --style compact --predicate 'process == "Limit Bar"'
    ;;
esac
