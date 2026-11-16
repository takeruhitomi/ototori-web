"""Render PNG launcher-icon assets from ototori_icon.svg.

Needs Pillow and a local Chrome/Edge (used headless as the SVG rasteriser):
    python render_icons.py
Outputs go to ./png next to this script.
"""
from __future__ import annotations

import re
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).resolve().parent
OUT = HERE / "png"
MASTER = (HERE / "ototori_icon.svg").read_text(encoding="utf-8")
BROWSERS = [
    Path(r"C:\Program Files\Google\Chrome\Application\chrome.exe"),
    Path(r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"),
]
RENDER = 1024
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}


def svg_variant(view_box: str, background: bool) -> str:
    svg = re.sub(r'viewBox="[^"]*"', f'viewBox="{view_box}"', MASTER, count=1)
    svg = re.sub(r'width="\d+" height="\d+"', f'width="{RENDER}" height="{RENDER}"', svg, count=1)
    if not background:
        svg = re.sub(r'<rect id="background"[^>]*/>', "", svg)
    return svg


def rasterise(svg: str) -> Image.Image:
    browser = next(p for p in BROWSERS if p.exists())
    with tempfile.TemporaryDirectory() as tmp:
        html = Path(tmp) / "icon.html"
        png = Path(tmp) / "icon.png"
        html.write_text(
            f"<html><body style='margin:0;background:transparent'>{svg}</body></html>",
            encoding="utf-8",
        )
        result = subprocess.run(
            [str(browser), "--headless=new", "--disable-gpu", "--hide-scrollbars",
             "--no-first-run", "--no-sandbox", f"--user-data-dir={Path(tmp) / 'profile'}",
             "--force-device-scale-factor=1", f"--window-size={RENDER},{RENDER}",
             "--default-background-color=00000000", f"--screenshot={png}",
             html.as_uri()],
            capture_output=True, text=True, timeout=60,
        )
        if not png.exists():
            raise RuntimeError(f"browser render failed ({result.returncode}): {result.stderr[-2000:]}")
        return Image.open(png).convert("RGBA").crop((0, 0, RENDER, RENDER))


def masked(img: Image.Image, shape: str) -> Image.Image:
    mask = Image.new("L", img.size, 0)
    draw = ImageDraw.Draw(mask)
    box = (0, 0, img.width - 1, img.height - 1)
    if shape == "circle":
        draw.ellipse(box, fill=255)
    else:
        draw.rounded_rectangle(box, radius=int(img.width * 0.2), fill=255)
    out = img.copy()
    out.putalpha(mask)
    return out


def save(img: Image.Image, rel: str, size: int) -> None:
    path = OUT / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    img.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def main() -> None:
    # Visible launcher area is the central 72dp of the 108dp canvas.
    full = rasterise(svg_variant("18 18 72 72", background=True))
    foreground = rasterise(svg_variant("0 0 108 108", background=False))

    save(full, "play_store_512.png", 512)
    save(full, "icon_full_1024.png", 1024)
    save(foreground, "adaptive_foreground_432.png", 432)
    rounded, circle = masked(full, "rounded"), masked(full, "circle")
    for density, size in DENSITIES.items():
        save(rounded, f"mipmap-{density}/ic_launcher.png", size)
        save(circle, f"mipmap-{density}/ic_launcher_round.png", size)
    print(f"wrote PNGs to {OUT}")


if __name__ == "__main__":
    main()
