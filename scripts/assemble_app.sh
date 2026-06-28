#!/usr/bin/env bash
#
# Assemble build/StatBar.app from `swift build` output — NO code signing.
#
# Shared by both pipelines:
#   scripts/build_release.sh  → assemble, then Developer ID sign + notarize
#   scripts/build_local.sh    → assemble, then ad-hoc re-sign for local launch
#
# Assembling/copying into the bundle ALWAYS breaks any existing signature seal,
# so every caller MUST sign afterwards (resign_local.sh or build_release.sh).
# Never `open` the bundle straight out of this script on Apple Silicon — the
# kernel will SIGKILL the unsealed binary.
#
# Usage: scripts/assemble_app.sh
set -euo pipefail

APP_NAME="StatBar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> swift build (release)"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/$APP_NAME"               "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Info.plist"             "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "==> assembled (UNSIGNED): $APP"
