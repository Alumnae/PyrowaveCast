#!/usr/bin/env python3
"""Regenerate every PyrowaveCast app icon from Resources/AppIcon/AppIcon.svg.

Outputs:
  - PyrowaveCastiOS/PyrowaveCastiOS/Assets.xcassets/AppIcon.appiconset   (iOS 17+, single 1024 universal)
  - PyrowaveCast/Assets.xcassets/AppIcon.appiconset            (iOS 1024 + macOS 16..1024)
  - Resources/AppIcon/AppIcon.icns                             (SwiftPM .app bundles, build-*.sh)
  - Resources/AppIcon/AppIcon-1024.png, AppIcon-macOS-1024.png (previews)

Requires macOS (qlmanage for SVG rasterising, iconutil for .icns) and Pillow.
Usage:  python3 Resources/AppIcon/generate.py
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
SVG = HERE / "AppIcon.svg"
RENDER = 2048  # supersampled master

IOS_SET = ROOT / "PyrowaveCastiOS/PyrowaveCastiOS/Assets.xcassets/AppIcon.appiconset"
MULTI_SET = ROOT / "PyrowaveCast/Assets.xcassets/AppIcon.appiconset"
MAC_SIZES = [16, 32, 128, 256, 512]


def render_svg(tmp: Path) -> Image.Image:
    subprocess.run(["qlmanage", "-t", "-s", str(RENDER), "-o", str(tmp), str(SVG)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return Image.open(tmp / (SVG.name + ".png")).convert("RGB")


def squircle_mask(size: int, n: float = 5.0) -> Image.Image:
    """Superellipse mask approximating Apple's continuous-corner icon shape."""
    ss = 4
    big = size * ss
    mask = Image.new("L", (big, big), 0)
    pts = []
    import math
    steps = 2000
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = (abs(c) ** (2 / n)) * (1 if c >= 0 else -1)
        y = (abs(s) ** (2 / n)) * (1 if s >= 0 else -1)
        pts.append(((x + 1) * big / 2, (y + 1) * big / 2))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask.resize((size, size), Image.LANCZOS)


def macos_master(full: Image.Image) -> Image.Image:
    """macOS Big Sur+ grid: 824/1024 squircle body, centred, with a soft drop shadow."""
    canvas = RENDER
    body = round(canvas * 824 / 1024)
    off = (canvas - body) // 2
    art = full.resize((body, body), Image.LANCZOS).convert("RGBA")
    mask = squircle_mask(body)
    out = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    shadow = Image.new("L", (canvas, canvas), 0)
    shadow.paste(mask, (off, off + round(canvas * 10 / 1024)))
    shadow = shadow.filter(ImageFilter.GaussianBlur(canvas * 10 / 1024))
    shadow = shadow.point(lambda v: int(v * 0.35))
    black = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 255))
    out = Image.composite(black, out, shadow)
    out.paste(art, (off, off), mask)
    return out


def save(img: Image.Image, path: Path, px: int, rgb: bool):
    im = img.resize((px, px), Image.LANCZOS)
    if rgb:
        im = im.convert("RGB")  # App Store rejects alpha in iOS icons
    im.save(path, optimize=True)


def write_contents(dirpath: Path, images):
    (dirpath / "Contents.json").write_text(json.dumps(
        {"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def ensure_catalog(catalog: Path):
    catalog.mkdir(parents=True, exist_ok=True)
    c = catalog / "Contents.json"
    if not c.exists():
        c.write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")


def main():
    with tempfile.TemporaryDirectory() as t:
        full = render_svg(Path(t))
    mac = macos_master(full)

    save(full, HERE / "AppIcon-1024.png", 1024, rgb=True)
    save(mac, HERE / "AppIcon-macOS-1024.png", 1024, rgb=False)

    # iOS app (iPhone + iPad, iOS 17+: single-size universal icon)
    ensure_catalog(IOS_SET.parent)
    if IOS_SET.exists():
        shutil.rmtree(IOS_SET)
    IOS_SET.mkdir()
    save(full, IOS_SET / "AppIcon-1024.png", 1024, rgb=True)
    write_contents(IOS_SET, [{"filename": "AppIcon-1024.png", "idiom": "universal",
                              "platform": "ios", "size": "1024x1024"}])

    # Multiplatform Xcode app (iOS + macOS)
    ensure_catalog(MULTI_SET.parent)
    if MULTI_SET.exists():
        shutil.rmtree(MULTI_SET)
    MULTI_SET.mkdir()
    save(full, MULTI_SET / "AppIcon-ios-1024.png", 1024, rgb=True)
    images = [{"filename": "AppIcon-ios-1024.png", "idiom": "universal",
               "platform": "ios", "size": "1024x1024"}]
    for s in MAC_SIZES:
        for scale in (1, 2):
            name = f"AppIcon-mac-{s}@{scale}x.png"
            save(mac, MULTI_SET / name, s * scale, rgb=False)
            images.append({"filename": name, "idiom": "mac",
                           "scale": f"{scale}x", "size": f"{s}x{s}"})
    write_contents(MULTI_SET, images)

    # .icns for SwiftPM-packaged macOS apps
    with tempfile.TemporaryDirectory() as t:
        iconset = Path(t) / "AppIcon.iconset"
        iconset.mkdir()
        for s in MAC_SIZES:
            save(mac, iconset / f"icon_{s}x{s}.png", s, rgb=False)
            save(mac, iconset / f"icon_{s}x{s}@2x.png", s * 2, rgb=False)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(HERE / "AppIcon.icns")],
                       check=True)
    print("App icons regenerated.")


if __name__ == "__main__":
    sys.exit(main())
