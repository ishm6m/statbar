#!/usr/bin/env bash
#
# StatBar release packager (SwiftPM → signed, notarized .app + .dmg).
#
# No Xcode required — assembles the .app bundle by hand from `swift build`
# output, embeds Sparkle.framework, signs with Hardened Runtime + entitlements,
# builds a DMG, then notarizes and staples.
#
# Required environment (export before running):
#   DEV_ID        "Developer ID Application: Your Name (TEAMID)"
#   TEAM_ID       your 10-char Apple Developer Team ID
#   APPLE_ID      Apple ID email used for notarization
#   APP_PW        app-specific password (appleid.apple.com → Sign-In & Security)
#
# Usage: scripts/build_release.sh
set -euo pipefail

APP_NAME="StatBar"
BUNDLE_ID="com.getstatbar.StatBar"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$BUILD_DIR/$APP_NAME.dmg"
ENTITLEMENTS="$ROOT/StatBar.entitlements"

: "${DEV_ID:?set DEV_ID}" "${TEAM_ID:?set TEAM_ID}" "${APPLE_ID:?set APPLE_ID}" "${APP_PW:?set APP_PW}"

# Assemble the bundle (shared with the local pipeline). Leaves $APP UNSIGNED.
"$ROOT/scripts/assemble_app.sh"

echo "==> codesign (inside-out, Hardened Runtime)"
SIGN=(codesign --force --options runtime --timestamp --sign "$DEV_ID")
# Sign Sparkle's nested helpers first, then the framework.
if [[ -d "$APP/Contents/Frameworks/Sparkle.framework" ]]; then
  FW="$APP/Contents/Frameworks/Sparkle.framework"
  find "$FW" \( -name "*.xpc" -o -name "*.app" \) -print0 | while IFS= read -r -d '' n; do
    "${SIGN[@]}" "$n"
  done
  "${SIGN[@]}" "$FW"
fi
# Sign the main executable with entitlements, then the bundle.
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP/Contents/MacOS/$APP_NAME"
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> build DMG"
command -v create-dmg >/dev/null || { echo "install: brew install create-dmg" >&2; exit 1; }
rm -f "$DMG"
create-dmg \
  --volname "$APP_NAME" \
  --volicon "$ROOT/Resources/AppIcon.icns" \
  --window-size 540 380 \
  --icon-size 110 \
  --icon "$APP_NAME.app" 140 190 \
  --app-drop-link 400 190 \
  "$DMG" "$APP"

echo "==> sign DMG"
"${SIGN[@]}" "$DMG"

echo "==> notarize (waits for Apple)"
xcrun notarytool submit "$DMG" \
  --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PW" --wait

echo "==> staple"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> done: $DMG"
