#!/usr/bin/env bash
#
# Local build: assemble build/StatBar.app, then ALWAYS ad-hoc re-sign it so it
# launches on Apple Silicon. This is the local equivalent of build_release.sh —
# no Developer ID, no notarization, no DMG.
#
# resign_local.sh runs unconditionally as the final step so developers never
# have to remember to re-sign after the bundle is (re)assembled. The build
# always leaves build/StatBar.app in a launchable, sealed state.
#
# Usage: scripts/build_local.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

"$ROOT/scripts/assemble_app.sh"
"$ROOT/scripts/resign_local.sh"
