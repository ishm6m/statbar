#!/usr/bin/env bash
#
# Re-sign build/StatBar.app with an ad-hoc signature for LOCAL launch.
#
# Why this exists: on Apple Silicon the kernel SIGKILLs any binary whose code
# signature seal is broken (crash log shows CODESIGNING / "Invalid Page"). Any
# edit to the bundle AFTER signing — copying a new Info.plist, install_name_tool,
# touching a resource — breaks the seal and the app silently fails to launch
# from Finder. This script re-seals everything inside-out so it launches again.
#
# Ad-hoc (-s -) is fine for running on THIS machine. For distribution use
# scripts/build_release.sh with a real Developer ID (Gatekeeper/notarization).
#
# Usage: scripts/resign_local.sh [path-to-.app]   (default build/StatBar.app)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/StatBar.app}"
[[ -d "$APP" ]] || { echo "app not found: $APP (run build_release.sh first)" >&2; exit 1; }

# Keep the bundle's Info.plist in sync with the source of truth before resealing.
if [[ -f "$ROOT/Info.plist" ]]; then
  cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
fi

echo "==> re-signing main binary + app shell"
codesign --force -s - "$APP/Contents/MacOS/StatBar"
codesign --force -s - "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP" >/dev/null && echo "    signature valid"

# Strip quarantine so Finder/double-click does not block the ad-hoc build.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
echo "==> done. Launch:  open \"$APP\""
