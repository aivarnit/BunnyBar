#!/usr/bin/env python3
"""Generate BunnyBar's original pixel-art sprites.

The bunny is drawn procedurally from simple shapes (ellipses, rotated ellipses,
single pixels) on a 32x32 grid, then outlined. Every animation frame is a
parameter set, so all frames share one consistent design.

Outputs (committed to the repository):
  addon/BunnyBar/Textures/bunny-idle.tga    128x32  idle, blink, ear twitch, breathe
  addon/BunnyBar/Textures/bunny-hop.tga      64x32  hop preparation (crouch), jump
  addon/BunnyBar/Textures/bunny-land.tga     32x32  landing squash
  addon/BunnyBar/Textures/bunny-sleepy.tga  256x32  getting sleepy (3), lying down (4)
  addon/BunnyBar/Textures/bunny-sleep.tga   256x32  breathing cycle (4), ear + nose twitch
  addon/BunnyBar/Textures/bunny-wake.tga    128x32  waking up (4)
  docs/images/sprite-preview.png                     all frames, one row per animation
  docs/images/sleep-preview.gif                      animated nap, using the in-game timings

Sheets whose frame count is not a power of two are padded with empty slots so
every texture keeps power-of-two dimensions.

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
GIF_PATH = ROOT / "docs" / "images" / "sleep-preview.gif"

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
ZZZ_FAINT = (150, 190, 255, 120)  # a "z" fading out
LID = (120, 104, 140, 255)        # drowsy upper eyelid


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
    eyes=None,
    mouth="normal",
    nose_twitch=False,
) -> Canvas:
    """Compose one bunny frame (facing right).

    eyes: "open" | "half" | "closed" (defaults from eyes_closed)
    mouth: "normal" | "yawn"
    """
    if eyes is None:
        eyes = "closed" if eyes_closed else "open"
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
    if eyes == "closed":
        c.set(ex - 1, ey + 1, EYE)
        c.set(ex, ey + 2, EYE)
        c.set(ex + 1, ey + 2, EYE)
        c.set(ex + 2, ey + 1, EYE)
    elif eyes == "half":
        # Heavy eyelid over the lower half of the eye.
        c.set(ex - 1, ey + 1, LID)
        c.set(ex, ey + 1, LID)
        c.set(ex + 1, ey + 1, LID)
        c.set(ex + 2, ey + 1, LID)
        c.set(ex, ey + 2, EYE)
        c.set(ex + 1, ey + 2, EYE)
    else:
        for dy in range(3):
            c.set(ex, ey + dy, EYE)
            c.set(ex + 1, ey + dy, EYE)
        c.set(ex + 1, ey, WHITE)  # catch-light
    nx, ny = int(round(hx + hrx - 0.6)), int(round(hy + 0.8))
    if nose_twitch:
        # Nose wrinkles up by one pixel and widens.
        c.set(nx, ny - 1, PINK_DARK)
        c.set(nx - 1, ny - 1, PINK)
    else:
        c.set(nx, ny, PINK_DARK)
    c.set(ex - 1, ey + 3, BLUSH)
    c.set(ex, ey + 3, BLUSH)
    if mouth == "yawn":
        # Small open mouth: dark with a pink tongue.
        c.set(nx - 1, ny + 1, EYE)
        c.set(nx - 2, ny + 1, EYE)
        c.set(nx - 1, ny + 2, PINK_DARK)
        c.set(nx - 2, ny + 2, EYE)
    else:
        c.set(nx - 1, ny + 1, SHADE_DARK)  # tiny mouth

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
        back_foot=(10.0, 28.0, 4.4, 1.3),
        front_paw=(20.0, 28.0, 2.4, 1.2),
        tail=(5.2, 22.5, 2.5),
    )

    sleepy, sleep, wake = sleep_frames()
    return {
        "bunny-idle": [idle, blink, twitch, breathe],
        "bunny-hop": [prep, jump],
        "bunny-land": [land],
        "bunny-sleepy": sleepy,
        "bunny-sleep": sleep,
        "bunny-wake": wake,
    }


# --------------------------------------------------------------------------
# Sleep animation: poses as parameter sets, interpolated for smooth motion
# --------------------------------------------------------------------------

# Upright sitting pose (identical to the idle frame).
SIT = dict(
    body=(14.0, 22.0, 8.0, 6.0),
    head=(21.0, 15.8, 6.4, 5.6),
    ears=((19.0, 12.0, 10.0, 0.18), (22.0, 11.5, 10.0, 0.02)),
    back_foot=(10.5, 27.8, 3.6, 1.6),
    front_paw=(19.5, 27.6, 1.9, 1.5),
    tail=(6.2, 20.0, 2.6),
)

# Nodding off: still sitting, head dipped, ears drooping, body settling.
NOD = dict(SIT,
    body=(14.0, 22.3, 8.1, 5.7),
    head=(21.3, 17.0, 6.4, 5.5),
    ears=((19.0, 13.2, 10.0, 0.60), (22.0, 12.7, 10.0, 0.45)),
)

# Curled up asleep. Body bottom stays on the same ground row as sitting;
# ears lie flat along the back; head rests in front of the body.
LIE = dict(
    body=(13.5, 24.0, 9.6, 5.0),
    head=(21.6, 21.2, 6.2, 5.2),
    ears=((18.6, 18.2, 11.0, 1.32), (20.4, 17.6, 11.0, 1.20)),
    back_foot=(11.0, 28.0, 3.0, 1.0),
    front_paw=(25.0, 28.0, 2.2, 1.0),
    tail=(4.6, 23.6, 2.4),
)

# Inhale: torso top rises exactly 1 px; the bottom edge stays put. The ears
# rest on the back, so they ride up with it by the same pixel.
LIE_IN = dict(LIE, body=(13.5, 23.5, 9.6, 5.5),
              ears=tuple((x, y - 1.0, l, a) for x, y, l, a in LIE["ears"]))

# Morning stretch: chest low and paws reaching forward, rump up.
STRETCH = dict(
    body=(13.5, 23.2, 9.4, 5.2),
    head=(22.4, 19.6, 6.2, 5.2),
    ears=((19.6, 15.4, 10.5, 0.72), (21.6, 14.8, 10.5, 0.56)),
    back_foot=(9.5, 28.0, 3.6, 1.0),
    front_paw=(26.0, 28.0, 2.6, 1.0),
    tail=(4.8, 19.8, 2.6),
)


def lerp_pose(a, b, t):
    def mix(x, y):
        if isinstance(x, tuple):
            return tuple(mix(i, j) for i, j in zip(x, y))
        return x + (y - x) * t
    return {k: mix(a[k], b[k]) for k in a}


def with_near_ear(pose, near):
    return dict(pose, ears=(pose["ears"][0], near))


# Rising "z" glyph: (x, y, big, faint) per breathing frame. One z drifts up
# and to the right a step per frame, grows, then fades out, and the cycle
# restarts with the next breath. Kept clear of the head (top row 15).
Z_FRAMES = [
    [(22, 10, False, False)],
    [(24, 7, False, False)],
    [(25, 3, True, False)],
    [(26, 0, True, True)],
]


def add_z(c: Canvas, specs):
    for x, y, big, faint in specs:
        n = 5 if big else 4
        col = ZZZ_FAINT if faint else ZZZ
        for i in range(n):
            c.set(x + i, y, col)
            c.set(x + i, y + n - 1, col)
        for i in range(1, n - 1):
            c.set(x + n - 1 - i, y + i, col)


def sleep_frames():
    """Return (sleepy sheet, sleep sheet, wake sheet) frame lists."""
    # Getting sleepy: heavy eyelids -> big yawn -> eyes shut, head nodding.
    drowsy = [
        draw_bunny(**lerp_pose(SIT, NOD, 0.25), eyes="half"),
        draw_bunny(**dict(lerp_pose(SIT, NOD, 0.45), head=(21.0, 15.6, 6.4, 5.6)),
                   eyes="closed", mouth="yawn"),
        draw_bunny(**NOD, eyes="closed"),
    ]
    # Lying down: ease from the nodding pose into the curled-up pose.
    lie_down = [draw_bunny(**lerp_pose(NOD, LIE, t), eyes="closed")
                for t in (0.3, 0.58, 0.82, 1.0)]

    def asleep(pose, z, **kw):
        c = draw_bunny(**pose, eyes="closed", **kw)
        add_z(c, z)
        return c

    # Breathing: rest, inhale, hold, exhale (torso 0 / +1 / +1 / 0 px).
    breathing = [
        asleep(LIE, Z_FRAMES[0]),
        asleep(LIE_IN, Z_FRAMES[1]),
        asleep(LIE_IN, Z_FRAMES[2]),
        asleep(LIE, Z_FRAMES[3]),
    ]
    near = LIE["ears"][1]
    ear_flick = asleep(with_near_ear(LIE, (near[0], near[1], near[2] - 0.6, near[3] - 0.32)),
                       Z_FRAMES[3])
    nose_twitch = asleep(LIE, Z_FRAMES[3], nose_twitch=True)

    # Waking up: eyes open -> head and ears rise -> stretch -> sit up.
    wake = [
        draw_bunny(**with_near_ear(LIE, (near[0], near[1], near[2] - 0.6, near[3] - 0.32)),
                   eyes="half"),
        draw_bunny(**lerp_pose(LIE, STRETCH, 0.55), eyes="open"),
        draw_bunny(**STRETCH, eyes="closed", mouth="yawn"),
        draw_bunny(**lerp_pose(STRETCH, SIT, 0.6), eyes="open"),
    ]
    return drowsy + lie_down, breathing + [ear_flick, nose_twitch], wake


# Frame timings (seconds). Mirrored by Bunny.SEQUENCES in Animation.lua; the
# test-suite checks the two stay in sync. Used here for the animated preview.
TIMINGS = {
    "drowsy": [0.24, 0.28, 0.22],
    "liedown": [0.15, 0.15, 0.16, 0.18],
    "breathe": [0.65, 0.55, 0.65, 0.55],
    "wake": [0.22, 0.20, 0.26, 0.20],
}

# Texture slot count per sheet (power of two >= frame count).
def slots_for(count):
    n = 1
    while n < count:
        n *= 2
    return n


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------

def strip(canvases):
    """Concatenate frames horizontally into one RGBA row-major pixel grid,
    padded with transparent slots to a power-of-two width."""
    slots = slots_for(len(canvases))
    w = FRAME * slots
    rows = []
    for y in range(FRAME):
        row = []
        for c in canvases:
            row.extend(c.px[y])
        row.extend([CLEAR] * (FRAME * (slots - len(canvases))))
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


BG_LIGHT, BG_DARK = (236, 232, 244, 255), (222, 216, 234, 255)
GROUND = (196, 186, 214, 255)


def blend(dst, src):
    a = src[3] / 255
    return tuple(round(src[i] * a + dst[i] * (1 - a)) for i in range(3)) + (255,)


def blit(rows, c: Canvas, x0, y0, scale):
    for y in range(FRAME):
        for x in range(FRAME):
            p = c.px[y][x]
            if p[3] == 0:
                continue
            for sy in range(scale):
                r = rows[y0 + y * scale + sy]
                for sx in range(scale):
                    r[x0 + x * scale + sx] = blend(r[x0 + x * scale + sx], p)


def preview_rows(sheets):
    """Frames grouped one animation per row for the static preview."""
    sleepy, sleep, wake = sheets["bunny-sleepy"], sheets["bunny-sleep"], sheets["bunny-wake"]
    return [
        sheets["bunny-idle"] + sheets["bunny-hop"] + sheets["bunny-land"],  # awake & hopping
        sleepy[:3] + sleepy[3:],   # getting sleepy (3) | lying down (4)
        sleep,                     # breathing (4) | ear twitch | nose twitch
        wake,                      # waking up (4)
    ]


def preview(sheets, scale=6, pad=4) -> bytes:
    """Static sheet: one animation group per row, upscaled nearest-neighbour."""
    groups = preview_rows(sheets)
    cell = FRAME * scale
    gap = pad * scale // 2
    cols = max(len(g) for g in groups)
    w = cols * cell + (cols + 1) * gap
    h = len(groups) * cell + (len(groups) + 1) * gap
    rows = [[BG_LIGHT if ((x // 16) + (y // 16)) % 2 == 0 else BG_DARK for x in range(w)]
            for y in range(h)]
    for gi, group in enumerate(groups):
        y0 = gap + gi * (cell + gap)
        for i, c in enumerate(group):
            blit(rows, c, gap + i * (cell + gap), y0, scale)
    return encode_png(w, h, rows)


def nap_timeline(sheets):
    """(canvas, seconds) pairs for one complete nap, using TIMINGS."""
    idle = sheets["bunny-idle"]
    sleepy, sleep, wake = sheets["bunny-sleepy"], sheets["bunny-sleep"], sheets["bunny-wake"]
    seq = [(idle[0], 1.0), (idle[1], 0.14), (idle[0], 0.6)]
    seq += list(zip(sleepy[:3], TIMINGS["drowsy"]))
    seq += list(zip(sleepy[3:], TIMINGS["liedown"]))
    seq += list(zip(sleep[:4], TIMINGS["breathe"]))
    seq += [(sleep[4], 0.3)]                       # ear twitch between breaths
    seq += list(zip(sleep[:4], TIMINGS["breathe"]))
    seq += [(sleep[5], 0.3)]                       # nose twitch
    seq += list(zip(sleep[:4], TIMINGS["breathe"]))
    seq += list(zip(wake, TIMINGS["wake"]))
    seq += [(idle[0], 0.8), (idle[2], 0.3), (idle[0], 0.6)]
    return seq


def lzw_encode(data: bytes, min_size: int) -> bytes:
    """GIF-flavoured LZW (variable code width, LSB-first packing)."""
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    out = bytearray()
    acc = nbits = 0
    size = min_size + 1

    def emit(code):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += size
        while nbits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            nbits -= 8

    def reset():
        return {bytes([i]): i for i in range(clear)}, eoi + 1, min_size + 1

    table, next_code, size = reset()
    emit(clear)
    w = b""
    for k in data:
        wk = w + bytes([k])
        if wk in table:
            w = wk
            continue
        emit(table[w])
        if next_code < 4096:
            table[wk] = next_code
            next_code += 1
            # The decoder adds its entries one code later than we do, so it
            # widens codes when our next_code passes 2**size.
            if next_code > (1 << size) and size < 12:
                size += 1
        else:
            emit(clear)
            table, next_code, size = reset()
        w = bytes([k])
    if w:
        emit(table[w])
    emit(eoi)
    if nbits:
        out.append(acc & 0xFF)
    return bytes(out)


def encode_gif(frames, w, h) -> bytes:
    """Minimal animated GIF89a encoder (stdlib only, global palette)."""
    palette = []
    index = {}
    for rows, _ in frames:
        for row in rows:
            for p in row:
                if p not in index:
                    index[p] = len(palette)
                    palette.append(p)
    if len(palette) > 256:
        raise ValueError(f"too many colours for preview GIF: {len(palette)}")
    bits = max(2, (len(palette) - 1).bit_length())
    palette += [(0, 0, 0, 255)] * ((1 << bits) - len(palette))

    out = bytearray(b"GIF89a")
    out += struct.pack("<HHBBB", w, h, 0xF0 | (bits - 1), 0, 0)
    for r, g, b, _ in palette:
        out += bytes((r, g, b))
    out += b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00"  # loop forever
    for rows, seconds in frames:
        delay = max(2, round(seconds * 100))
        out += b"\x21\xF9\x04" + struct.pack("<BHBB", 0x04, delay, 0, 0)
        out += b"\x2C" + struct.pack("<HHHHB", 0, 0, w, h, 0)
        data = lzw_encode(bytes(index[p] for row in rows for p in row), bits)
        out.append(bits)
        for i in range(0, len(data), 255):
            block = data[i:i + 255]
            out.append(len(block))
            out += block
        out.append(0)
    out.append(0x3B)
    return bytes(out)


def nap_gif(sheets, scale=5) -> bytes:
    size = FRAME * scale
    w, h = size + 4 * scale, size + 2 * scale
    ground_y = 2 * scale // 2 + 30 * scale  # just under the feet (row 29)
    frames_out = []
    for c, seconds in nap_timeline(sheets):
        rows = [[BG_LIGHT] * w for _ in range(h)]
        for x in range(scale, w - scale):
            rows[ground_y][x] = GROUND
        blit(rows, c, 2 * scale, scale, scale)
        frames_out.append((rows, seconds))
    return encode_gif(frames_out, w, h)


def build():
    sheets = frames()
    outputs = {}
    for name, canvases in sheets.items():
        w, h, rows = strip(canvases)
        outputs[TEXTURE_DIR / f"{name}.tga"] = encode_tga(w, h, rows)
    outputs[PREVIEW_PATH] = preview(sheets)
    outputs[GIF_PATH] = nap_gif(sheets)
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
