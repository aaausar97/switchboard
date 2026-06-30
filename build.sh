#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="${APP_PATH:-/Applications/Switchboard.app}"
BUILD_DIR="$ROOT_DIR/.build"
EXECUTABLE="$BUILD_DIR/switchboard"

mkdir -p "$BUILD_DIR" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

echo "Compiling Switchboard..."
swiftc -o "$EXECUTABLE" \
  "$ROOT_DIR/main.swift" \
  "$ROOT_DIR/AltTabManager.swift" \
  "$ROOT_DIR/AudioRecorder.swift" \
  "$ROOT_DIR/AudioDownloader.swift" \
  "$ROOT_DIR/DictationManager.swift" \
  -framework Cocoa \
  -framework Carbon \
  -framework CoreGraphics \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework ApplicationServices

echo "Updating app bundle at $APP_PATH..."
cp "$EXECUTABLE" "$APP_PATH/Contents/MacOS/switchboard"
cp "$ROOT_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
if [ -d "$ROOT_DIR/Resources" ]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_PATH/Contents/Resources/"
fi

echo "Signing app bundle..."
codesign --force --deep --sign - "$APP_PATH"

if [ "${1:-}" = "--launch" ]; then
  killall switchboard 2>/dev/null || true
  open "$APP_PATH"
fi

echo "Done. Launch $APP_PATH to test."
