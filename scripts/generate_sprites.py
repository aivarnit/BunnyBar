#!/usr/bin/env python3
"""Generate BunnyBar's original pixel-art sprites.

The bunny is drawn procedurally from simple shapes (ellipses, rotated ellipses,
single pixels) on a 32x32 grid, then outlined. Every animation frame is a
parameter set, so all frames share one consistent design.

Outputs (committed to the repository):
  addon/BunnyBar/Textures/bunny-idle.tga   128x32  idle, blink, ear twitch, breathe
  addon/BunnyBar/Textures/bunny-hop.tga     64x32  hop preparation (crouch), jump
  addon/BunnyBar/Textures/bunny-land.tga    32x32  landing squash
  addon/BunnyBar/Textures/bunny-sleep.tga   64x32  sleeping (two breathing frames)
  docs/images/sprite-preview.png                    8x nearest-neighbour preview

Only the Python standard library is used. TGA files are uncompressed 32-bit
BGRA with an 8-bit alpha channel and top-left origin, which the WoW client loads
directly. All texture dimensions are powers of two.

Usage:
  python3 scripts/generate_sprites.py           # write assets
  python3 scripts/generate_sprites.py --check   # verify committed assets match
"""
from __future__ import annotations

import argparse
import math
import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TEXTURE_DIR = ROOT / "addon" / "BunnyBar" / "Textures"
PREVIEW_PATH = ROOT / "docs" / "images" / "sprite-preview.png"

FRAME = 32  # sprite size in pixels

# Palette (RGBA)
CLEAR = (0, 0, 0, 0)
OUTLINE = (58, 44, 66, 255)       # deep plum, softer than black
WHITE = (255, 255, 255, 255)
FUR = (246, 243, 250, 255)        # main fur
SHADE = (214, 206, 230, 255)      # belly / underside shading
SHADE_DARK = (186, 176, 208, 255)  # deepest shade (far limbs)
PINK = (247, 160, 190, 255)       # inner ears
PINK_DARK = (226, 112, 150, 255)  # nose
BLUSH = (252, 196, 212, 255)      # cheek
EYE = (34, 24, 40, 255)
ZZZ = (150, 190, 255, 255)        # sleep "z" glyphs


class Canvas:
    def __init__(self, w: int = FRAME, h: int = FRAME):
        self.w, self.h = w, h
        self.px = [[CLEAR] * w for _ in range(h)]

    def get(self, x: int, y: int):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.px[y][x]
        return CLEAR

    def set(self, x: int, y: int, c) -> None:
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y][x] = c

    def ellipse(self, cx, cy, rx, ry, color, angle=0.0, shade=None, shade_from=0.45):
        """Fill a (rotated) ellipse. Pixels whose local y lies below
        `shade_from` (fraction of ry) get the `shade` colour instead."""
        ca, sa = math.cos(angle), math.sin(angle)
        r = int(max(rx, ry)) + 2
        for y in range(int(cy) - r, int(cy) + r + 1):
            for x in range(int(cx) - r, int(cx) + r + 1):
                dx, dy = x + 0.5 - cx, y + 0.5 - cy
                lx = dx * ca + dy * sa
                ly = -dx * sa + dy * ca
                if (lx / rx) ** 2 + (ly / ry) ** 2 <= 1.0:
                    c = color
                    if shade is not None and dy > ry * shade_from:
                        c = shade
                    self.set(x, y, c)

    def outline(self, color=OUTLINE) -> None:
        """Add a 1px 4-connected outline around all opaque pixels."""
        add = []
        for y in range(self.h):
            for x in range(self.w):
                if self.px[y][x][3] == 0:
                    for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                        if self.get(nx, ny)[3] != 0 and self.get(nx, ny) != color:
                            add.append((x, y))
                            break
        for x, y in add:
            self.set(x, y, color)


def ear(c: Canvas, base_x, base_y, length, angle, inner=True, shade=False):
    """Draw an ear rooted at (base_x, base_y) pointing in direction `angle`
    (radians, 0 = straight up, positive = tilted backward/left)."""
    cx = base_x - math.sin(angle) * length * 0.5
    cy = base_y - math.cos(angle) * length * 0.5
    c.ellipse(cx, cy, 2.1, length * 0.5 + 0.6, SHADE if shade else FUR, angle=-angle)
    if inner:
        icx = base_x - math.sin(angle) * length * 0.55
        icy = base_y - math.cos(angle) * length * 0.55
        c.ellipse(icx, icy, 0.85, length * 0.36, PINK, angle=-angle)


def ear_outline(c: Canvas, base_x, base_y, length, angle):
    """Outline pass for a single ear so the two ears read as separate shapes."""
    cx = base_x - math.sin(angle) * length * 0.5
    cy = base_y - math.cos(angle) * length * 0.5
    c.ellipse(cx, cy, 3.1, length * 0.5 + 1.6, OUTLINE, angle=-angle)


def draw_bunny(
    *,
    body=(14.0, 22.0, 8.0, 6.0),
    head=(21.0, 15.8, 6.4, 5.6),
    ears=((19.0, 12.0, 10.0, 0.15), (22.0, 11.5, 10.0, 0.0)),
    eyes_closed=False,
    back_foot=(10.5, 27.8, 3.6, 1.6),
    front_paw=(19.5, 27.6, 1.9, 1.5),
    tail=(6.2, 20.0, 2.6),
) -> Canvas:
    """Compose one bunny frame (facing right)."""
    c = Canvas()
    bx, by, brx, bry = body
    hx, hy, hrx, hry = head

    # Far ear first (drawn slightly darker so it sits behind).
    far, near = ears
    ear_outline(c, *far)
    ear(c, *far, inner=False, shade=True)

    # Tail, feet, body silhouette outline (drawn larger, then filled).
    tx, ty, tr = tail
    c.ellipse(tx, ty, tr + 1, tr + 1, OUTLINE)
    if back_foot:
        fx, fy, frx, fry = back_foot
        c.ellipse(fx, fy, frx + 1, fry + 1, OUTLINE)
    c.ellipse(bx, by, brx + 1, bry + 1, OUTLINE)
    c.ellipse(hx, hy, hrx + 1, hry + 1, OUTLINE)

    c.ellipse(tx, ty, tr, tr, WHITE)
    if back_foot:
        c.ellipse(fx, fy, frx, fry, SHADE)
    c.ellipse(bx, by, brx, bry, FUR, shade=SHADE, shade_from=0.35)
    # Near ear sits over the head outline.
    ear_outline(c, *near)
    c.ellipse(hx, hy, hrx, hry, FUR, shade=SHADE, shade_from=0.55)
    ear(c, *near)
    # Re-fill the ear root so it merges into the head.
    nbx, nby = near[0], near[1]
    c.ellipse(nbx, nby + 1.2, 1.7, 1.5, FUR)

    if front_paw:
        px, py, prx, pry = front_paw
        c.ellipse(px, py, prx + 1, pry + 1, OUTLINE)
        c.ellipse(px, py, prx, pry, FUR)

    # Face (relative to head centre).
    ex, ey = int(round(hx + 1.2)), int(round(hy - 1.6))
    if eyes_closed:
        c.set(ex - 1, ey + 1, EYE)
        c.set(ex, ey + 2, EYE)
        c.set(ex + 1, ey + 2, EYE)
        c.set(ex + 2, ey + 1, EYE)
    else:
        for dy in range(3):
            c.set(ex, ey + dy, EYE)
            c.set(ex + 1, ey + dy, EYE)
        c.set(ex + 1, ey, WHITE)  # catch-light
    nx, ny = int(round(hx + hrx - 0.6)), int(round(hy + 0.8))
    c.set(nx, ny, PINK_DARK)
    c.set(ex - 1, ey + 3, BLUSH)
    c.set(ex, ey + 3, BLUSH)
    # Tiny mouth.
    c.set(nx - 1, ny + 1, SHADE_DARK)

    c.outline()
    return c


def zzz(c: Canvas, x: int, y: int, big: bool) -> None:
    """Tiny 'z' glyph (4x4, or 5x5 when big)."""
    n = 5 if big else 4
    for i in range(n):
        c.set(x + i, y, ZZZ)
        c.set(x + i, y + n - 1, ZZZ)
    for i in range(1, n - 1):
        c.set(x + n - 1 - i, y + i, ZZZ)


# --------------------------------------------------------------------------
# Frame definitions
# --------------------------------------------------------------------------

def frames():
    base_ears = ((19.0, 12.0, 10.0, 0.18), (22.0, 11.5, 10.0, 0.02))

    idle = draw_bunny(ears=base_ears)
    blink = draw_bunny(ears=base_ears, eyes_closed=True)
    twitch = draw_bunny(ears=((19.0, 12.0, 10.0, 0.18), (22.0, 11.5, 9.6, -0.22)))
    breathe = draw_bunny(
        body=(14.0, 22.3, 8.2, 5.8),
        head=(21.0, 16.0, 5.6, 5.0),
        ears=((19.0, 12.5, 10.0, 0.22), (22.0, 12.0, 10.0, 0.06)),
    )

    prep = draw_bunny(
        body=(13.5, 23.5, 8.6, 5.0),
        head=(21.0, 18.0, 5.6, 4.8),
        ears=((18.5, 14.5, 9.5, 0.55), (21.5, 14.0, 9.5, 0.42)),
        back_foot=(10.0, 28.0, 4.2, 1.4),
        front_paw=(19.5, 28.0, 2.2, 1.2),
        tail=(5.5, 22.0, 2.6),
    )
    jump = draw_bunny(
        body=(14.0, 19.5, 8.8, 5.4),
        head=(22.0, 13.5, 5.5, 4.9),
        ears=((19.0, 10.0, 10.5, 0.75), (22.0, 9.5, 10.5, 0.6)),
        back_foot=(6.5, 25.0, 4.0, 1.5),
        front_paw=(24.0, 21.5, 2.0, 1.4),
        tail=(5.2, 17.0, 2.6),
    )
    land = draw_bunny(
        body=(14.0, 24.0, 9.0, 4.8),
        head=(21.5, 18.5, 5.8, 4.7),
        ears=((19.5, 15.0, 9.0, -0.15), (22.5, 14.5, 9.0, -0.38)),
        back_foot=(10.0, 28.3, 4.4, 1.3),
        front_paw=(20.0, 28.2, 2.4, 1.2),
        tail=(5.2, 22.5, 2.5),
    )

    def sleeping(inhale: bool, z_frame: int) -> Canvas:
        c = draw_bunny(
            body=(13.0, 24.5, 9.6, 5.0 if inhale else 4.6),
            head=(21.0, 22.0 if inhale else 22.3, 5.6, 4.6),
            # Ears lie flat along the back.
            ears=((18.0, 19.5, 11.0, 1.32), (20.0, 19.0, 11.0, 1.22)),
            eyes_closed=True,
            back_foot=None,
            front_paw=(25.5, 28.4, 2.2, 1.1),
            tail=(3.8, 23.5, 2.4),
        )
        if z_frame == 0:
            zzz(c, 24, 11, big=False)
        else:
            zzz(c, 26, 9, big=False)
            zzz(c, 20, 3, big=True)
        return c

    return {
        "bunny-idle": [idle, blink, twitch, breathe],
        "bunny-hop": [prep, jump],
        "bunny-land": [land],
        "bunny-sleep": [sleeping(True, 0), sleeping(False, 1)],
    }


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------

def strip(canvases):
    """Concatenate frames horizontally into one RGBA row-major pixel grid."""
    w = FRAME * len(canvases)
    rows = []
    for y in range(FRAME):
        row = []
        for c in canvases:
            row.extend(c.px[y])
        rows.append(row)
    return w, FRAME, rows


def encode_tga(w, h, rows) -> bytes:
    # Uncompressed true-colour (type 2), 32bpp, 8 alpha bits, top-left origin.
    header = struct.pack(
        "<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 32, 0x28
    )
    body = bytearray()
    for row in rows:
        for r, g, b, a in row:
            if a == 0:
                r = g = b = 0  # keep fully transparent pixels clean
            body += bytes((b, g, r, a))
    return header + bytes(body)


def encode_png(w, h, rows) -> bytes:
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for px in row:
            raw += bytes(px)

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )


def preview(sheets, scale=8, pad=4) -> bytes:
    """Lay every frame out on a checkered background, upscaled nearest-neighbour."""
    all_frames = [c for name in sheets for c in sheets[name]]
    cols = len(all_frames)
    cell = FRAME * scale
    w = cols * cell + (cols + 1) * pad * scale // 2
    h = cell + pad * scale
    light, dark = (236, 232, 244, 255), (222, 216, 234, 255)
    rows = []
    for y in range(h):
        row = []
        for x in range(w):
            row.append(light if ((x // 16) + (y // 16)) % 2 == 0 else dark)
        rows.append(row)
    ox = pad * scale // 2
    oy = pad * scale // 2
    for i, c in enumerate(all_frames):
        x0 = ox + i * (cell + pad * scale // 2)
        for y in range(FRAME):
            for x in range(FRAME):
                p = c.px[y][x]
                if p[3] == 0:
                    continue
                for sy in range(scale):
                    r = rows[oy + y * scale + sy]
                    for sx in range(scale):
                        r[x0 + x * scale + sx] = p
    return encode_png(w, h, rows)


def build():
    sheets = frames()
    outputs = {}
    for name, canvases in sheets.items():
        w, h, rows = strip(canvases)
        outputs[TEXTURE_DIR / f"{name}.tga"] = encode_tga(w, h, rows)
    outputs[PREVIEW_PATH] = preview(sheets)
    return outputs


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="verify committed assets are up to date; write nothing")
    args = ap.parse_args(argv)

    outputs = build()
    if args.check:
        stale = [p for p, data in outputs.items()
                 if not p.exists() or p.read_bytes() != data]
        for p in stale:
            print(f"STALE: {p.relative_to(ROOT)}")
        if stale:
            print("Run: python3 scripts/generate_sprites.py")
            return 1
        print(f"OK: {len(outputs)} generated assets are up to date")
        return 0

    for path, data in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"wrote {path.relative_to(ROOT)} ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
