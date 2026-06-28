#!/usr/bin/env python3
"""Regenerate every derived brand asset from the single source logo.

Source of truth:  statbar-logo.png  (repo root — NEVER modified by this script)

Outputs:
  Resources/Assets.xcassets/AppIcon.appiconset/*.png   macOS .appiconset (1x/2x)
  Resources/AppIcon.icns                                bundled app icon (via iconutil)
  web/*.png, web/favicon.ico                            website / favicon assets

The artwork is preserved exactly: no recolor, no crop, no stylize. The source is
slightly non-square, so it is centered on a transparent square canvas (padding
only — never stretched) before any resize. All downscales use Lanczos.

Run:  python3 scripts/generate_icons.py
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "statbar-logo.png"

APPICONSET = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICNS = ROOT / "Resources" / "AppIcon.icns"
WEB = ROOT / "web"

# macOS .appiconset entries: (base point size, scale) -> pixel size.
APPICON_VARIANTS = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

# Web assets: filename -> pixel size.
WEB_PNGS = {
    "favicon-16x16.png": 16,
    "favicon-32x32.png": 32,
    "apple-touch-icon-180x180.png": 180,
    "icon-192x192.png": 192,
    "icon-512x512.png": 512,
}
FAVICON_ICO_SIZES = [16, 32, 48]


def load_square_master() -> Image.Image:
    """Load the source and center it on a transparent square canvas.

    Padding only — the artwork is never cropped or stretched. Returns an RGBA
    image whose side == max(width, height) of the source.
    """
    img = Image.open(SRC).convert("RGBA")
    w, h = img.size
    side = max(w, h)
    if (w, h) == (side, side):
        return img
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(img, ((side - w) // 2, (side - h) // 2))
    print(f"  padded {w}x{h} -> {side}x{side} (centered, no crop)")
    return canvas


def resized(master: Image.Image, px: int) -> Image.Image:
    return master.resize((px, px), Image.Resampling.LANCZOS)


def write(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")
    print(f"  wrote {path.relative_to(ROOT)} ({img.width}x{img.height})")


def build_appiconset(master: Image.Image) -> list[Path]:
    written = []
    for base, scale in APPICON_VARIANTS:
        px = base * scale
        name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@{scale}x.png"
        out = APPICONSET / name
        write(resized(master, px), out)
        written.append(out)
    return written


def build_icns(master: Image.Image) -> None:
    """Assemble a .iconset and convert to .icns with the native iconutil."""
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for base, scale in APPICON_VARIANTS:
            px = base * scale
            name = f"icon_{base}x{base}.png" if scale == 1 else f"icon_{base}x{base}@{scale}x.png"
            resized(master, px).save(iconset / name, "PNG")
        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS)],
            check=True,
        )
    print(f"  wrote {ICNS.relative_to(ROOT)} (via iconutil)")


def build_web(master: Image.Image) -> None:
    for name, px in WEB_PNGS.items():
        write(resized(master, px), WEB / name)
    ico = WEB / "favicon.ico"
    base = resized(master, max(FAVICON_ICO_SIZES))
    base.save(ico, sizes=[(s, s) for s in FAVICON_ICO_SIZES])
    print(f"  wrote {ico.relative_to(ROOT)} ({'/'.join(map(str, FAVICON_ICO_SIZES))})")


def main() -> int:
    if not SRC.exists():
        print(f"error: source logo not found: {SRC}", file=sys.stderr)
        return 1
    print(f"source: {SRC.relative_to(ROOT)} ({Image.open(SRC).size[0]}x{Image.open(SRC).size[1]})")
    master = load_square_master()

    print("appiconset:")
    build_appiconset(master)
    print("icns:")
    build_icns(master)
    print("web:")
    build_web(master)
    print("done.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
