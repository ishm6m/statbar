#!/usr/bin/env bash
#
# Package build/StatBar.app into a versioned, checksummed ZIP for beta testers.
#
# Steps (fail-fast — any error aborts with non-zero status, no partial artifact):
#   1. Read CFBundleShortVersionString + CFBundleVersion from Info.plist.
#   2. Name the ZIP from the version: StatBar-v<short>.zip, or
#      StatBar-v<short>-build<build>.zip when the build number differs.
#   3. Delete older beta ZIPs (and their .sha256 sidecars).
#   4. Archive with `ditto -c -k --keepParent` (preserves Sparkle.framework
#      symlinks/resource forks; plain `zip` corrupts them).
#   5. Write a SHA-256 sidecar (`shasum -c`-compatible).
#   6. Round-trip verify: extract into a temp dir and confirm a valid StatBar.app
#      comes back out (codesign --verify --deep --strict).
#   7. Print absolute ZIP path, size, and SHA-256.
#
# Assumes build/StatBar.app already assembled + signed (the Makefile runs
# build_local.sh first). Run standalone only after a build.
#
# Usage: scripts/package_beta.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/StatBar.app"
PLIST="$APP/Contents/Info.plist"

[[ -d "$APP" ]] || { echo "app not found: $APP (run build_local.sh first)" >&2; exit 1; }

# 1. Version from the bundle's own Info.plist (the artifact's source of truth).
SHORT="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")"
[[ -n "$SHORT" ]] || { echo "CFBundleShortVersionString empty" >&2; exit 1; }

# 2. Name: include build only when it carries extra info (differs from short).
if [[ -n "$BUILD" && "$BUILD" != "$SHORT" ]]; then
  NAME="StatBar-v${SHORT}-build${BUILD}"
else
  NAME="StatBar-v${SHORT}"
fi
ZIP="$BUILD_DIR/$NAME.zip"
SUM="$ZIP.sha256"

# 3. Remove older beta ZIPs + sidecars so only the current version remains.
rm -f "$BUILD_DIR"/StatBar-v*.zip "$BUILD_DIR"/StatBar-v*.zip.sha256

# 4. Archive (ditto preserves bundle structure; same as Finder "Compress").
echo "==> ditto -> $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 5. SHA-256 sidecar. Stored as "<hash>  <basename>" so `shasum -c StatBar-*.sha256`
#    works when run from the build/ directory.
( cd "$BUILD_DIR" && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256" )
HASH="$(awk '{print $1}' "$SUM")"

# 6. Round-trip: extract to a temp dir and verify a valid app comes back.
echo "==> verifying archive round-trips to a valid StatBar.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ditto -x -k "$ZIP" "$TMP"
[[ -d "$TMP/StatBar.app" ]] || { echo "extracted bundle missing: $TMP/StatBar.app" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$TMP/StatBar.app"

# 7. Report.
SIZE="$(du -h "$ZIP" | cut -f1)"
printf '\n==> beta package ready\n'
printf '    zip:    %s\n' "$ROOT/build/$NAME.zip"
printf '    size:   %s\n' "$SIZE"
printf '    sha256: %s\n' "$HASH"
