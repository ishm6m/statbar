#!/bin/sh
# Capture the StatBar menu-bar popup, cropped, into docs/images/.
# Usage: scripts/capture_popup.sh [outfile]   (default docs/images/popup.png)
# Needs Screen Recording + Accessibility granted to the terminal.
# Stage a CLEAN/NEUTRAL desktop first — the popup is translucent and bleeds
# whatever is behind it through. # ponytail: generous fixed crop; trim in Preview.
set -e
out="${1:-docs/images/popup.png}"
app="System Events to tell process \"StatBar\""

open -g build/StatBar.app 2>/dev/null || true
sleep 1
# status-item logical position/size: "x, y, w, h"
geom=$(osascript -e "tell application \"$app\" to get {position, size} of menu bar item 1 of menu bar 2")
x=$(echo "$geom" | cut -d, -f1 | tr -d ' ')
w=$(echo "$geom" | cut -d, -f3 | tr -d ' ')
# popup is 320pt wide, centred under the item; retina = 2x
cx=$(( (x + w/2) * 2 ))
left=$(( cx - 360 ))          # 320pt popup + margin, in px
osascript -e "tell application \"$app\" to click menu bar item 1 of menu bar 2"
sleep 1
tmp=$(mktemp /tmp/statbar.XXXX).png
screencapture -x "$tmp"
sips --cropToHeightWidth 1500 760 --cropOffset 50 "$left" "$tmp" --out "$out" >/dev/null
osascript -e "tell application \"$app\" to click menu bar item 1 of menu bar 2"  # close
rm -f "$tmp"
echo "wrote $out — open it, crop tight to the panel, run pngquant/ImageOptim."
