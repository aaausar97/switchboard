#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/WindowOwnerExclusionTests"
mkdir -p "$BUILD_DIR" "$ROOT_DIR/.build/ModuleCache" "$ROOT_DIR/.build/tmp"
export TMPDIR="$ROOT_DIR/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"

swiftc -parse-as-library -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
  "$ROOT_DIR/AltTabManager.swift" \
  "$ROOT_DIR/Tests/WindowOwnerExclusionTests.swift" \
  -framework Cocoa -framework CoreGraphics \
  -framework ScreenCaptureKit -framework ApplicationServices \
  -o "$BUILD_DIR/window-owner-exclusion-tests"

"$BUILD_DIR/window-owner-exclusion-tests"
