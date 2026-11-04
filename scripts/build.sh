#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/.build"
APP="$ROOT/dist/AgentHistory.app"
TARGET="arm64-apple-macos14.0"

mkdir -p "$BUILD"

echo "[1/4] 编译核心与测试"
swiftc -swift-version 5 -O -target "$TARGET" \
  "$ROOT"/Sources/Core/*.swift "$ROOT"/Tests/main.swift \
  -o "$BUILD/agent-history-tests" -lsqlite3

echo "[2/4] 运行测试"
"$BUILD/agent-history-tests"

echo "[3/4] 编译应用"
swiftc -swift-version 5 -O -target "$TARGET" \
  "$ROOT"/Sources/main.swift "$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/UI/*.swift \
  -o "$BUILD/AgentHistory" -lsqlite3

echo "[4/4] 组装应用包"
if [ -e "$APP" ]; then
  OLD="$BUILD/AgentHistory.app.old.$(date +%s)"
  mv "$APP" "$OLD"
  # 只留最近一份旧包，避免 .build 越堆越大
  ls -dt "$BUILD"/AgentHistory.app.old.* 2>/dev/null | tail -n +2 | while read -r d; do
    find "$d" -delete 2>/dev/null || true
  done
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/AgentHistory" "$APP/Contents/MacOS/AgentHistory"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AgentHistory.icns" "$APP/Contents/Resources/AgentHistory.icns"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE"
cp "$ROOT/NOTICE" "$APP/Contents/Resources/NOTICE"
xattr -cr "$APP"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "完成：$APP"
