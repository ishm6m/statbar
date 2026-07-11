#!/usr/bin/env bash
#
# Stamp a release version everywhere it lives, so Info.plist and version.json
# can never drift apart (the drift makes a shipped build prompt users to
# "update" to itself).
#
# Usage: scripts/set_version.sh <version> [release-notes]
#   scripts/set_version.sh 1.2 "• Fixed live clocks"
#
# Writes:
#   Info.plist    CFBundleShortVersionString = <version>, CFBundleVersion += 1
#   version.json  version = <version>, publishedAt = now,
#                 releaseNotes = [release-notes] when given
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/set_version.sh <version> [release-notes]}"
NOTES="${2:-}"

BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"
NEXT_BUILD=$((BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEXT_BUILD" Info.plist

VERSION="$VERSION" NOTES="$NOTES" python3 - <<'PY'
import json, os, datetime

with open("version.json") as f:
    manifest = json.load(f)

manifest["version"] = os.environ["VERSION"]
manifest["publishedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if os.environ["NOTES"]:
    manifest["releaseNotes"] = os.environ["NOTES"]

with open("version.json", "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PY

echo "Stamped $VERSION (build $NEXT_BUILD) into Info.plist and version.json"
