#!/usr/bin/env python3
"""
Cyberpunk City Wallpaper Generator — uses only Pillow (PIL).
Creates a 1920x1080 wallpaper: starfield sky, city skyline with neon
reflections, perspective grid, glows, scanlines, and film grain.

Usage:
    python3 generate_wallpaper.py [--width W] [--height H] [--output PATH]

Default output: ~/.config/wallpaper/wallpaper.png
"""

import argparse
import math
import os
import random
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
except ImportError:
    print("Pillow not found — install with: apt install python3-pil")
    raise SystemExit(1)

# Cyberpunk palette
BG        = (5,   5,   15)
SKY_TOP   = (8,   8,   22)
SKY_MID   = (10,  12,  28)
GROUND    = (3,   3,   10)
CYAN      = (0,   229, 255)
MAGENTA   = (255, 0,   204)
GREEN     = (0,   255, 65)
PURPLE    = (153, 0,   255)
ORANGE    = (255, 107, 35)
YELLOW    = (255, 220, 0)

random.seed(42)


def _blend(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def _draw_glow(img, cx, cy, color, radius, layers=12, strength=0.55):
    glow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(glow)
    for i in range(layers, 0, -1):
        r = int(radius * i / layers)
        a = int(255 * (1 - i / layers) ** 1.8 * strength)
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(*color, a))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=max(radius // 6, 2)))
    img.paste(glow, (0, 0), glow)


def _draw_line_glow(img, x1, y1, x2, y2, color, width=2, blur=4, alpha=180):
    layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    for w in range(width + blur * 2, 0, -1):
        a = int(alpha * (1 - w / (width + blur * 2 + 1)) ** 1.5)
        d.line([(x1, y1), (x2, y2)], fill=(*color, a), width=w)
    img.paste(layer, (0, 0), layer)


def _draw_starfield(img, w, h, n=600):
    d = ImageDraw.Draw(img)
    for _ in range(n):
        x = random.randint(0, w - 1)
        y = random.randint(0, int(h * 0.62))
        brightness = random.randint(120, 255)
        size = random.choices([1, 2, 3], weights=[70, 25, 5])[0]
        col = (brightness, brightness, min(255, brightness + 30))
        if size == 1:
            d.point((x, y), fill=col)
        else:
            d.ellipse([x - size // 2, y - size // 2,
                       x + size // 2, y + size // 2], fill=col)


def _draw_grid(img, w, h, horizon_y, color, alpha=60):
    """Perspective grid on the ground plane below the horizon."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    vx = w // 2

    # Vertical lines radiating from vanishing point
    n_radial = 24
    for i in range(n_radial + 1):
        bx = int(w * i / n_radial)
        d.line([(vx, horizon_y), (bx, h)], fill=(*color, alpha), width=1)

    # Horizontal grid lines (perspective foreshortening)
    n_horiz = 14
    for i in range(1, n_horiz + 1):
        t = (i / n_horiz) ** 1.6
        y = int(horizon_y + (h - horizon_y) * t)
        a = int(alpha * (1 - (1 - t) ** 2))
        d.line([(0, y), (w, y)], fill=(*color, a), width=1)

    layer = layer.filter(ImageFilter.GaussianBlur(radius=0.5))
    img.paste(layer, (0, 0), layer)


def _building(draw, x, top, width, height, color, win_color, win_alpha=80):
    """Draw a single building rectangle with lit windows."""
    draw.rectangle([x, top, x + width, top + height], fill=color)
    # Windows — small bright rectangles
    ww, wh = 4, 5
    cols = max(1, (width - 4) // 8)
    rows = max(1, (height - 8) // 10)
    for r in range(rows):
        for c in range(cols):
            if random.random() < 0.55:
                wx = x + 4 + c * 8
                wy = top + 6 + r * 10
                w_col = random.choice([win_color, CYAN, YELLOW, (255, 255, 220)])
                draw.rectangle([wx, wy, wx + ww, wy + wh], fill=(*w_col, win_alpha))


def _draw_skyline(img, w, h, horizon_y):
    """City skyline — tall buildings silhouetted against the neon sky."""
    layer = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    building_defs = []
    x = 0
    while x < w:
        bw = random.randint(20, 90)
        bh = random.randint(60, int(h * 0.38))
        building_defs.append((x, bw, bh))
        x += bw + random.randint(0, 6)

    # Back layer — shorter, darker
    for bx, bw, bh in building_defs:
        top = horizon_y - int(bh * 0.55)
        col = _blend(GROUND, (18, 8, 30), random.random() * 0.5)
        _building(d, bx, top, bw, horizon_y - top, col, CYAN, 50)

    # Front layer — taller, darker silhouette
    for bx, bw, bh in building_defs:
        top = horizon_y - bh
        col = _blend(BG, (12, 5, 20), random.random() * 0.3)
        _building(d, bx, top, bw, horizon_y - top, col, YELLOW, 90)

    # Antenna spires on random buildings
    for bx, bw, bh in building_defs:
        if random.random() < 0.25:
            top = horizon_y - bh
            mid_x = bx + bw // 2
            spire_h = random.randint(15, 45)
            d.line([(mid_x, top), (mid_x, top - spire_h)],
                   fill=(*CYAN, 160), width=1)
            d.ellipse([mid_x - 3, top - spire_h - 3,
                       mid_x + 3, top - spire_h + 3],
                      fill=(*MAGENTA, 200))

    img.paste(layer, (0, 0), layer)


def _draw_reflection(img, w, h, horizon_y):
    """Neon reflections on the 'wet street' ground plane."""
    # Flip and fade the top half of the image below the horizon
    ground_h = h - horizon_y
    if ground_h <= 0:
        return

    top_strip = img.crop((0, horizon_y - ground_h, w, horizon_y))
    flipped = top_strip.transpose(Image.FLIP_TOP_BOTTOM)

    # Darken + add noise for wet-surface effect
    fade = Image.new("RGBA", (w, ground_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(fade)
    for y in range(ground_h):
        t = y / ground_h
        a = int(200 + 55 * t)  # more opaque toward bottom
        d.line([(0, y), (w, y)], fill=(0, 0, 0, a))

    flipped = flipped.convert("RGBA")
    flipped.paste(fade, (0, 0), fade)
    img.paste(flipped, (0, horizon_y), flipped)


def _scanlines(img, alpha=7):
    w, h = img.size
    scan = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(scan)
    for y in range(0, h, 2):
        d.line([(0, y), (w - 1, y)], fill=(0, 0, 0, alpha))
    img.paste(scan, (0, 0), scan)


def _film_grain(img, w, h, density=0.08):
    px = img.load()
    for _ in range(int(w * h * density)):
        x = random.randint(0, w - 1)
        y = random.randint(0, h - 1)
        r, g, b = px[x, y]
        n = random.randint(-8, 8)
        px[x, y] = (max(0, min(255, r + n)),
                    max(0, min(255, g + n)),
                    max(0, min(255, b + n)))


def generate(width=1920, height=1080, output=None):
    if output is None:
        output = Path.home() / ".config" / "wallpaper" / "wallpaper.png"
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)

    w, h = width, height
    horizon_y = int(h * 0.60)

    # ── Sky gradient ───────────────────────────────────────────
    img = Image.new("RGBA", (w, h))
    d = ImageDraw.Draw(img)
    for y in range(horizon_y):
        t = y / horizon_y
        col = _blend(_blend(SKY_TOP, SKY_MID, t), (15, 5, 35), t * 0.4)
        d.line([(0, y), (w, y)], fill=(*col, 255))

    # ── Ground (below horizon) ─────────────────────────────────
    for y in range(horizon_y, h):
        t = (y - horizon_y) / max(h - horizon_y, 1)
        col = _blend(GROUND, (2, 2, 8), t)
        d.line([(0, y), (w, y)], fill=(*col, 255))

    # ── Stars ──────────────────────────────────────────────────
    _draw_starfield(img, w, h)

    # ── Background neon glows in sky ───────────────────────────
    r_lg = int(min(w, h) * 0.5)
    _draw_glow(img, int(w * 0.15), int(h * 0.20), CYAN,    r_lg,     14, 0.35)
    _draw_glow(img, int(w * 0.85), int(h * 0.15), MAGENTA, int(r_lg * 0.8), 14, 0.30)
    _draw_glow(img, int(w * 0.50), int(h * 0.55), PURPLE,  int(r_lg * 0.6), 10, 0.20)

    # ── Perspective grid on ground ─────────────────────────────
    _draw_grid(img, w, h, horizon_y, CYAN, alpha=55)

    # ── City skyline ───────────────────────────────────────────
    _draw_skyline(img, w, h, horizon_y)

    # ── Horizon glow line ──────────────────────────────────────
    for gw, ga in [(3, 180), (8, 80), (20, 30)]:
        gl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        gd = ImageDraw.Draw(gl)
        gd.line([(0, horizon_y), (w, horizon_y)], fill=(*CYAN, ga), width=gw)
        img.paste(gl, (0, 0), gl)

    # ── Wet street reflection ──────────────────────────────────
    _draw_reflection(img, w, h, horizon_y)

    # ── Foreground accent glows (above horizon line) ───────────
    _draw_glow(img, int(w * 0.05), horizon_y, CYAN,    int(r_lg * 0.35), 10, 0.50)
    _draw_glow(img, int(w * 0.95), horizon_y, MAGENTA, int(r_lg * 0.30), 10, 0.45)
    _draw_glow(img, int(w * 0.50), horizon_y, PURPLE,  int(r_lg * 0.20),  8, 0.25)

    # ── Neon accent lines (horizontal streaks near horizon) ────
    streak_y = horizon_y - 2
    for color, alpha in [(CYAN, 120), (MAGENTA, 80)]:
        sl = Image.new("RGBA", (w, h), (0, 0, 0, 0))
        sd = ImageDraw.Draw(sl)
        sd.line([(0, streak_y), (w, streak_y)], fill=(*color, alpha), width=1)
        sl = sl.filter(ImageFilter.GaussianBlur(radius=1))
        img.paste(sl, (0, 0), sl)

    # ── Scanlines ──────────────────────────────────────────────
    _scanlines(img, alpha=9)

    # ── Film grain ─────────────────────────────────────────────
    img_rgb = img.convert("RGB")
    _film_grain(img_rgb, w, h, density=0.06)

    img_rgb.save(str(output), "PNG", compress_level=6)
    print(f"Wallpaper saved → {output}  ({w}x{h})")


def main():
    p = argparse.ArgumentParser(description="Generate a cyberpunk city wallpaper")
    p.add_argument("--width",  type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--output", type=str, default=None)
    a = p.parse_args()
    generate(a.width, a.height, a.output)


if __name__ == "__main__":
    main()
