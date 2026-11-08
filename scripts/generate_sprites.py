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

  addon/BunnyBar/Textures/bunny-ears.tga     32x32  portrait ears (32x16 frame)
  addon/BunnyBar/Textures/bunny-icon.tga     32x32  AddOns-list icon (single layer)
  docs/images/sprite-preview.png                     also shows colour variants + ears

Every texture holds TWO layers of the same frames, stacked vertically:
  top half    = fur only, normalised so the main fur tone is pure white; the
                addon tints it with SetVertexColor(fur colour), so shading
                keeps its original ratios in any colour
  bottom half = every non-fur detail (outline, eyes, nose, inner ears, blush,
                z glyphs), never tinted
The two layers never overlap. With the default fur colour (#F6F3FA, the
original fur tone) the composite reproduces the original art (within 1/255).

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
WHITE = (255, 255, 255, 255)       # eye catch-light (detail layer)
TAIL = (250, 248, 253, 255)        # cotton tail (fur layer)
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
    front_paw2=None,
    foot_front=False,
    face=1,
    look_up=False,
    blush_big=False,
    carrot=None,
    style=None,
) -> Canvas:
    """Compose one bunny frame (facing right).

    eyes: "open" | "half" | "closed" | "happy" (defaults from eyes_closed)
    mouth: "normal" | "yawn" | "tongue"
    face: 1 = profile (default), 0 = turned towards the viewer, -1 = looking back
    front_paw2: optional second front paw (both paws raised)
    foot_front: draw the hind foot in front of the body/head (scratching)
    carrot: optional ((base_x, base_y), (dir_x, dir_y), length) held carrot
    style: a Style (variation) whose hooks add horns, wings, tails, patches...
    """
    if eyes is None:
        eyes = "closed" if eyes_closed else "open"
    style = style or CLASSIC
    P = dict(body=body, head=head, ears=ears, back_foot=back_foot, front_paw=front_paw,
             tail=tail, face=face, eyes=eyes)
    ears = style.ears(ears)
    P["ears"] = ears
    c = Canvas()
    bx, by, brx, bry = body
    hx, hy, hrx, hry = head

    # Far ear first (drawn slightly darker so it sits behind).
    far, near = ears
    ear_outline(c, *far)
    ear(c, *far, inner=False, shade=True)
    style.behind(c, P)

    # Tail, feet, body silhouette outline (drawn larger, then filled).
    tx, ty, tr = tail
    custom_tail = style.has_tail
    if not custom_tail:
        c.ellipse(tx, ty, tr + 1, tr + 1, OUTLINE)
    if back_foot and not foot_front:
        fx, fy, frx, fry = back_foot
        c.ellipse(fx, fy, frx + 1, fry + 1, OUTLINE)
    c.ellipse(bx, by, brx + 1, bry + 1, OUTLINE)
    c.ellipse(hx, hy, hrx + 1, hry + 1, OUTLINE)

    if custom_tail:
        style.tail(c, P)
    else:
        c.ellipse(tx, ty, tr, tr, TAIL)
    if back_foot and not foot_front:
        c.ellipse(fx, fy, frx, fry, SHADE)
    c.ellipse(bx, by, brx, bry, FUR, shade=SHADE, shade_from=0.35)
    # Near ear sits over the head outline.
    ear_outline(c, *near)
    c.ellipse(hx, hy, hrx, hry, FUR, shade=SHADE, shade_from=0.55)
    ear(c, *near)
    # Re-fill the ear root so it merges into the head.
    nbx, nby = near[0], near[1]
    c.ellipse(nbx, nby + 1.2, 1.7, 1.5, FUR)

    style.fur_marks(c, P)

    if back_foot and foot_front:
        fx, fy, frx, fry = back_foot
        c.ellipse(fx, fy, frx + 1, fry + 1, OUTLINE)
        c.ellipse(fx, fy, frx, fry, SHADE)

    for paw in (front_paw2, front_paw):
        if paw:
            px, py, prx, pry = paw
            c.ellipse(px, py, prx + 1, pry + 1, OUTLINE)
            c.ellipse(px, py, prx, pry, FUR)

    if face != 1:
        draw_face_turned(c, P, face, eyes, look_up, blush_big)
        style.face(c, P, None)
        if carrot:
            draw_carrot(c, *carrot)
        style.over_head(c, P)
        c.outline()
        style.after_outline(c, P)
        return c

    # Face (relative to head centre).
    ex, ey = int(round(hx + 1.2)), int(round(hy - 1.6))
    if look_up:
        ey -= 1
    if eyes == "happy":
        # Content, closed "^" eyes.
        c.set(ex - 1, ey + 2, EYE)
        c.set(ex, ey + 1, EYE)
        c.set(ex + 1, ey + 1, EYE)
        c.set(ex + 2, ey + 2, EYE)
    elif eyes == "closed":
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
    if look_up:
        ny -= 1
    if nose_twitch:
        # Nose wrinkles up by one pixel and widens.
        c.set(nx, ny - 1, PINK_DARK)
        c.set(nx - 1, ny - 1, PINK)
    else:
        c.set(nx, ny, PINK_DARK)
    c.set(ex - 1, ey + 3, BLUSH)
    c.set(ex, ey + 3, BLUSH)
    if blush_big:
        c.set(ex - 2, ey + 3, BLUSH)
        c.set(ex + 1, ey + 3, BLUSH)
        c.set(ex - 1, ey + 4, BLUSH)
    if mouth == "tongue":
        c.set(nx - 1, ny + 1, SHADE_DARK)
        c.set(nx, ny + 1, PINK_DARK)
    elif mouth == "yawn":
        # Small open mouth: dark with a pink tongue.
        c.set(nx - 1, ny + 1, EYE)
        c.set(nx - 2, ny + 1, EYE)
        c.set(nx - 1, ny + 2, PINK_DARK)
        c.set(nx - 2, ny + 2, EYE)
    else:
        c.set(nx - 1, ny + 1, SHADE_DARK)  # tiny mouth
    style.face(c, P, (ex, ey, nx, ny))

    if carrot:
        draw_carrot(c, *carrot)
    style.over_head(c, P)
    c.outline()
    style.after_outline(c, P)
    return c


def draw_face_turned(c: Canvas, P, face, eyes, look_up, blush_big):
    """Face for a head turned towards the viewer (0) or looking back (-1)."""
    hx, hy, hrx, hry = P["head"]
    ey = int(round(hy - 1.6)) - (1 if look_up else 0)
    if face == 0:
        eye_xs = [int(round(hx - 2.8)), int(round(hx + 1.6))]
        nx, ny = int(round(hx)), int(round(hy + 0.8))
    else:
        eye_xs = [int(round(hx - 1.2)) - 2]
        nx, ny = int(round(hx - hrx + 0.6)) - 1, int(round(hy + 0.8))
    for ex in eye_xs:
        if eyes in ("closed", "happy"):
            c.set(ex, ey + 2, EYE)
            c.set(ex + 1, ey + 2, EYE)
        else:
            for dy in range(3):
                c.set(ex, ey + dy, EYE)
                c.set(ex + 1, ey + dy, EYE)
            c.set(ex + (1 if face == 0 else 0), ey, WHITE)
        c.set(ex, ey + 3, BLUSH)
        c.set(ex + 1, ey + 3, BLUSH)
        if blush_big:
            c.set(ex - 1, ey + 3, BLUSH)
    c.set(nx, ny, PINK_DARK)
    if face == 0:
        c.set(nx - 1, ny + 1, SHADE_DARK)
        c.set(nx + 1, ny + 1, SHADE_DARK)
    else:
        c.set(nx + 1, ny + 1, SHADE_DARK)


# Carrot (detail layer; never tinted).
CARROT = (244, 136, 44, 255)
CARROT_DARK = (204, 92, 30, 255)
LEAF = (104, 182, 76, 255)
LEAF_DARK = (58, 128, 56, 255)


def draw_carrot(c: Canvas, base, direction, length):
    """Carrot from its leafy top at `base` towards its tip along `direction`
    (unit vector), `length` pixels of orange. length 0 = leaves only."""
    bx, by = base
    dx, dy = direction
    # Leaves sprout from the base, away from the tip.
    for i, (lx, ly) in enumerate(((-0.6, 1.0), (0.6, 1.2), (0.0, 1.6))):
        for k in range(1, 3):
            c.set(int(round(bx - dx * k + lx * k * 0.6)), int(round(by - dy * k + ly * k * 0.5)),
                  LEAF if k == 1 else LEAF_DARK)
    steps = int(length * 2)
    for i in range(steps + 1):
        t = i / 2
        if t > length:
            break
        w = 1.4 * (1 - t / (length + 1.5)) if length else 0
        px, py = bx + dx * t, by + dy * t
        c.set(int(round(px)), int(round(py)), CARROT)
        if w > 0.7:
            # Thicker near the top; darker ridge on one side.
            c.set(int(round(px - dy)), int(round(py + dx)), CARROT_DARK)


def zzz(c: Canvas, x: int, y: int, big: bool) -> None:
    """Tiny 'z' glyph (4x4, or 5x5 when big)."""
    n = 5 if big else 4
    for i in range(n):
        c.set(x + i, y, ZZZ)
        c.set(x + i, y + n - 1, ZZZ)
    for i in range(1, n - 1):
        c.set(x + n - 1 - i, y + i, ZZZ)


# --------------------------------------------------------------------------
# Styles (bunny variations)
# --------------------------------------------------------------------------
#
# Every style is drawn from the SAME pose data. A style only adds features
# relative to the pose's head/body/tail (horns, halo, wings, tails, patches,
# stitches) through these hooks, so all animations work for every style.
# Fur pixels use the FUR/SHADE/TAIL (+ style fur tones) palette and are
# tinted in game; every other colour is a fixed detail colour.

# Style detail colours (never tinted)
DEVIL_HORN = (72, 34, 48, 255)
DEVIL_HORN_HI = (130, 70, 88, 255)
DEVIL_TAIL = (176, 36, 52, 255)
DEVIL_TAIL_DARK = (120, 20, 36, 255)
DEVIL_GLINT = (255, 96, 96, 255)
HALO = (255, 214, 84, 255)
HALO_DARK = (214, 158, 40, 255)
SPARKLE = (255, 244, 170, 255)
WING = (252, 252, 255, 255)
WING_SHADE = (206, 216, 240, 255)
DRAGON_HORN = (240, 226, 182, 255)
DRAGON_HORN_SHADE = (190, 168, 118, 255)
DRAGON_WING = (124, 94, 172, 255)
DRAGON_WING_BONE = (80, 58, 122, 255)
STITCH = (66, 52, 74, 255)
ZOMBIE_BLUSH = (200, 214, 170, 255)

# Extra fur tones (tinted with the fur colour, darker/lighter than the main fur)
PATCH = (222, 226, 204, 255)   # zombie patchwork
SCALE = (204, 200, 220, 255)   # dragon scales


class Style:
    """Classic bunny: no extras. Subclasses override the hooks."""
    id, label, default_fur = "classic", "Classic", "F6F3FA"
    has_tail = False

    def ears(self, ears):
        return ears

    def behind(self, c, P):       # after the far ear, before the body (wings)
        pass

    def tail(self, c, P):         # custom tail (only if has_tail)
        pass

    def fur_marks(self, c, P):    # after body/head fill (patches, scales)
        pass

    def face(self, c, P, pos):    # after the face (brows, glints); pos=None if turned
        pass

    def over_head(self, c, P):    # last before outlining (horns, stitches)
        pass

    def after_outline(self, c, P):  # unoutlined extras (halo, sparkles)
        pass


def head_top(P):
    hx, hy, hrx, hry = P["head"]
    return hx, hy - hry


def _tri(c, pts, colour):
    """Fill a small triangle (pixel centres inside)."""
    (x1, y1), (x2, y2), (x3, y3) = pts
    lo_x, hi_x = int(min(x1, x2, x3)) - 1, int(max(x1, x2, x3)) + 1
    lo_y, hi_y = int(min(y1, y2, y3)) - 1, int(max(y1, y2, y3)) + 1
    def side(ax, ay, bx, by, px, py):
        return (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    for y in range(lo_y, hi_y + 1):
        for x in range(lo_x, hi_x + 1):
            px, py = x + 0.5, y + 0.5
            d1, d2, d3 = side(x1, y1, x2, y2, px, py), side(x2, y2, x3, y3, px, py), side(x3, y3, x1, y1, px, py)
            if (d1 >= 0 and d2 >= 0 and d3 >= 0) or (d1 <= 0 and d2 <= 0 and d3 <= 0):
                c.set(x, y, colour)


def _line(c, pts, colour):
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        n = int(max(abs(bx - ax), abs(by - ay)) * 2) + 1
        for i in range(n + 1):
            t = i / n
            c.set(int(round(ax + (bx - ax) * t)), int(round(ay + (by - ay) * t)), colour)


class Devil(Style):
    id, label, default_fur = "devil", "Devil", "E06E7C"
    has_tail = True

    def tail(self, c, P):
        tx, ty, tr = P["tail"]
        pts = [(tx + 2.5, ty + 0.5), (tx, ty - 0.5), (tx - 2.5, ty - 2.5), (tx - 3.5, ty - 5.0)]
        _line(c, pts, DEVIL_TAIL)
        ex, ey = pts[-1]
        _tri(c, [(ex - 2.2, ey + 0.6), (ex + 1.8, ey + 0.4), (ex - 0.6, ey - 3.0)], DEVIL_TAIL_DARK)

    def face(self, c, P, pos):
        if not pos:
            return
        ex, ey, nx, ny = pos
        if P["eyes"] == "open":
            c.set(ex + 1, ey, DEVIL_GLINT)        # red glint
            c.set(ex - 1, ey - 1, EYE)            # mischievous slanted brow
            c.set(ex, ey - 1, EYE)
            c.set(ex + 1, ey - 2, EYE)
        c.set(nx - 2, ny + 1, SHADE_DARK)         # smirk

    def over_head(self, c, P):
        hx, top = head_top(P)
        hrx = P["head"][2]
        # One horn on the forehead (in front of the ears), one behind them.
        for bx, by, h, lean in ((hx + 3.8, top + 2.4, 4.6, 1.4), (hx - 3.6, top + 1.6, 4.0, -1.0)):
            _tri(c, [(bx - 1.7, by), (bx + 1.7, by), (bx + lean, by - h)], DEVIL_HORN)
            c.set(int(round(bx + lean * 0.5)), int(round(by - h * 0.55)), DEVIL_HORN_HI)


class Angel(Style):
    id, label, default_fur = "angel", "Angel", "FFF6E6"

    def behind(self, c, P):
        bx, by, brx, bry = P["body"]
        wx, wy = bx - brx * 0.35, by - bry * 0.85
        for k, (dx, dy, rx, ry, a) in enumerate(((-1.5, -2.5, 1.6, 4.2, 0.9), (-3.0, -0.8, 1.5, 4.0, 1.25),
                                                 (-3.6, 1.4, 1.3, 3.4, 1.6))):
            c.ellipse(wx + dx, wy + dy, rx + 1, ry + 1, OUTLINE, angle=a)
        for k, (dx, dy, rx, ry, a) in enumerate(((-1.5, -2.5, 1.6, 4.2, 0.9), (-3.0, -0.8, 1.5, 4.0, 1.25),
                                                 (-3.6, 1.4, 1.3, 3.4, 1.6))):
            c.ellipse(wx + dx, wy + dy, rx, ry, WING if k != 1 else WING_SHADE, angle=a)

    def face(self, c, P, pos):
        if pos:
            ex, ey, nx, ny = pos
            c.set(ex - 2, ey + 3, BLUSH)
            c.set(ex + 1, ey + 3, BLUSH)   # rosier, gentler cheeks

    def after_outline(self, c, P):
        hx, top = head_top(P)
        cx, cy = hx - 0.5, top - 2.6
        for x in range(int(cx - 5), int(cx + 6)):
            for y in range(int(cy - 2), int(cy + 3)):
                dx, dy = (x + 0.5 - cx) / 4.6, (y + 0.5 - cy) / 1.5
                d = dx * dx + dy * dy
                if 0.45 <= d <= 1.05:
                    c.set(x, y, HALO if y + 0.5 < cy else HALO_DARK)
        if int(hx * 7 + top * 3) % 2 == 0:
            c.set(int(cx + 5.5), int(cy - 2), SPARKLE)
            c.set(int(cx - 6), int(cy + 1), SPARKLE)
        else:
            c.set(int(cx + 4), int(cy - 3), SPARKLE)


class Dragon(Style):
    id, label, default_fur = "dragon", "Dragon", "86C784"
    has_tail = True

    def behind(self, c, P):
        bx, by, brx, bry = P["body"]
        rx, ry = bx - brx * 0.1, by - bry * 0.7
        tip1, tip2, tip3 = (rx - 7.0, ry - 6.5), (rx - 8.5, ry - 1.5), (rx - 5.5, ry + 1.5)
        _tri(c, [(rx + 1.5, ry), tip1, tip2], OUTLINE)
        _tri(c, [(rx + 1.5, ry), tip2, tip3], OUTLINE)
        _tri(c, [(rx + 0.6, ry + 0.4), (tip1[0] + 0.8, tip1[1] + 1.2), (tip2[0] + 1.0, tip2[1])], DRAGON_WING)
        _tri(c, [(rx + 0.6, ry + 0.4), (tip2[0] + 1.0, tip2[1]), (tip3[0] + 0.6, tip3[1] - 0.6)], DRAGON_WING)
        _line(c, [(rx + 0.5, ry), (tip1[0] + 1.0, tip1[1] + 1.4)], DRAGON_WING_BONE)
        _line(c, [(rx + 0.5, ry), (tip2[0] + 1.2, tip2[1])], DRAGON_WING_BONE)

    def tail(self, c, P):
        tx, ty, tr = P["tail"]
        segs = [(tx + 1.5, ty + 0.8, 2.4), (tx - 1.0, ty + 0.2, 1.9), (tx - 3.2, ty - 0.8, 1.4), (tx - 5.0, ty - 2.0, 1.0)]
        for x, y, r in segs:
            c.ellipse(x, y, r + 1, r + 1, OUTLINE)
        for x, y, r in segs:
            c.ellipse(x, y, r, r, FUR, shade=SHADE, shade_from=0.3)
        for x, y, r in segs[:3]:
            _tri(c, [(x - 0.9, y - r + 0.2), (x + 0.9, y - r + 0.2), (x, y - r - 1.6)], DRAGON_WING)

    def fur_marks(self, c, P):
        bx, by, brx, bry = P["body"]
        for k in range(3):
            x, y = int(round(bx - 3 + k * 3)), int(round(by - bry + 2.2 + (k % 2)))
            for dx, dy in ((0, 0), (1, 1), (-1, 1)):
                if c.get(x + dx, y + dy) in (FUR, SHADE):
                    c.set(x + dx, y + dy, SCALE)

    def over_head(self, c, P):
        hx, top = head_top(P)
        for bx, h in ((hx + 1.2, 4.2), (hx - 2.6, 3.6)):
            base_y = top + 1.6
            _tri(c, [(bx - 1.0, base_y), (bx + 1.2, base_y), (bx - 1.8, base_y - h)], DRAGON_HORN)
            c.set(int(round(bx - 0.4)), int(round(base_y - 0.6)), DRAGON_HORN_SHADE)


class Zombie(Style):
    id, label, default_fur = "zombie", "Zombie", "A9C4A2"

    def ears(self, ears):
        (fx, fy, fl, fa), near = ears
        return ((fx, fy, fl * 0.82, fa + 1.15), near)   # far ear flops over

    def fur_marks(self, c, P):
        bx, by, brx, bry = P["body"]
        hx, hy, hrx, hry = P["head"]
        patches = [(bx - 2.5, by - 1.0, 3.0), (hx - 2.2, hy + 1.6, 2.0)]
        for px_, py_, r in patches:
            for y in range(int(py_ - r) - 1, int(py_ + r) + 2):
                for x in range(int(px_ - r) - 1, int(px_ + r) + 2):
                    if (x + 0.5 - px_) ** 2 + (y + 0.5 - py_) ** 2 <= r * r and c.get(x, y) in (FUR, SHADE):
                        c.set(x, y, PATCH)
        # Stitches across the body patch edge.
        px_, py_, r = patches[0]
        for k in (-1, 1):
            x = int(round(px_ + r * 0.9))
            y = int(round(py_ + k * 1.2))
            if c.get(x, y)[3]:
                c.set(x, y, STITCH)
                c.set(x + 1, y - 1, STITCH)

    def face(self, c, P, pos):
        if not pos:
            return
        ex, ey, nx, ny = pos
        if P["eyes"] == "open":
            for dx in (-1, 0, 1, 2):
                c.set(ex + dx, ey, LID)           # sleepy, uneven lid
            c.set(ex + 1, ey + 1, WHITE)
        c.set(ex - 1, ey + 3, ZOMBIE_BLUSH)
        c.set(ex, ey + 3, ZOMBIE_BLUSH)
        c.set(nx - 1, ny + 1, CLEAR)
        c.set(nx - 2, ny + 1, SHADE_DARK)         # crooked little mouth

    def over_head(self, c, P):
        # Stitches across the near ear.
        bx, by, length, a = P["ears"][1]
        for k in (0.45, 0.7):
            cx = bx - math.sin(a) * length * k
            cy = by - math.cos(a) * length * k
            for d in (-1.2, 0, 1.2):
                c.set(int(round(cx + d * math.cos(a))), int(round(cy + d * math.sin(a))), STITCH)


CLASSIC = Style()
STYLES = [CLASSIC, Devil(), Angel(), Dragon(), Zombie()]
STYLE_BY_ID = {st.id: st for st in STYLES}


# --------------------------------------------------------------------------
# Frame definitions
# --------------------------------------------------------------------------

# Hop poses (8): anticipation (crouch), push-off, rising, apex, falling,
# contact, squash, recovery. Air poses are picked by the hop's progress.
ANTICIPATE = dict(
    body=(13.5, 23.5, 8.6, 5.0), head=(21.0, 18.0, 5.6, 4.8),
    ears=((18.5, 14.5, 9.5, 0.55), (21.5, 14.0, 9.5, 0.42)),
    back_foot=(10.0, 28.0, 4.2, 1.4), front_paw=(19.5, 28.0, 2.2, 1.2), tail=(5.5, 22.0, 2.6))
PUSH = dict(
    body=(14.5, 21.0, 8.6, 5.4), head=(22.4, 15.0, 6.0, 5.2),
    ears=((19.4, 11.2, 10.2, 0.62), (22.2, 10.8, 10.2, 0.48)),
    back_foot=(7.0, 27.6, 4.4, 1.3), front_paw=(23.5, 23.5, 2.0, 1.4), tail=(5.6, 19.5, 2.6))
RISE = dict(
    body=(14.0, 19.5, 8.8, 5.4), head=(22.0, 13.5, 5.5, 4.9),
    ears=((19.0, 10.0, 10.5, 0.75), (22.0, 9.5, 10.5, 0.6)),
    back_foot=(6.5, 25.0, 4.0, 1.5), front_paw=(24.0, 21.5, 2.0, 1.4), tail=(5.2, 17.0, 2.6))
APEX = dict(
    body=(14.5, 19.0, 8.2, 5.8), head=(22.0, 13.2, 6.2, 5.4),
    ears=((19.4, 9.6, 10.0, 0.40), (22.2, 9.2, 10.0, 0.25)),
    back_foot=(11.0, 24.5, 3.4, 1.4), front_paw=(20.5, 24.5, 1.8, 1.4), tail=(6.4, 17.5, 2.6))
FALL = dict(
    body=(14.5, 20.0, 8.4, 5.6), head=(22.4, 15.6, 6.0, 5.2),
    ears=((19.6, 11.6, 10.2, 0.30), (22.4, 11.2, 10.2, 0.12)),
    back_foot=(12.0, 25.5, 3.6, 1.4), front_paw=(22.0, 26.0, 2.0, 1.5), tail=(6.0, 18.5, 2.6))
CONTACT = dict(
    body=(14.2, 21.6, 8.2, 5.8), head=(21.8, 16.4, 6.2, 5.4),
    ears=((19.4, 12.6, 10.0, 0.10), (22.2, 12.2, 10.0, -0.12)),
    back_foot=(11.0, 26.5, 3.6, 1.5), front_paw=(21.0, 27.6, 2.1, 1.5), tail=(6.0, 19.8, 2.6))
SQUASH = dict(
    body=(14.0, 24.0, 9.0, 4.8), head=(21.5, 18.5, 5.8, 4.7),
    ears=((19.5, 15.0, 9.0, -0.15), (22.5, 14.5, 9.0, -0.38)),
    back_foot=(10.0, 28.0, 4.4, 1.3), front_paw=(20.0, 28.0, 2.4, 1.2), tail=(5.2, 22.5, 2.5))

BASE_EARS = ((19.0, 12.0, 10.0, 0.18), (22.0, 11.5, 10.0, 0.02))


def hop_frames(st):
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    return [d(ANTICIPATE), d(PUSH), d(RISE), d(APEX), d(FALL), d(CONTACT),
            d(SQUASH), d(lerp_pose(SQUASH, SIT, 0.6))]


def frames(style="classic"):
    st = STYLE_BY_ID[style] if isinstance(style, str) else style
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    base_ears = BASE_EARS
    idle = d(ears=base_ears)
    blink = d(ears=base_ears, eyes_closed=True)
    twitch = d(ears=((19.0, 12.0, 10.0, 0.18), (22.0, 11.5, 9.6, -0.22)))
    breathe = d(
        body=(14.0, 22.3, 8.2, 5.8),
        head=(21.0, 16.0, 5.6, 5.0),
        ears=((19.0, 12.5, 10.0, 0.22), (22.0, 12.0, 10.0, 0.06)),
    )
    sleepy, sleep, wake = sleep_frames(st)
    return {
        "bunny-idle": [idle, blink, twitch, breathe],
        "bunny-hop": hop_frames(st),
        "bunny-sleepy": sleepy,
        "bunny-sleep": sleep,
        "bunny-wake": wake,
        "bunny-carrot": carrot_frames(st),
        "bunny-groom": groom_frames(st),
        "bunny-moves": moves_frames(st),
        "bunny-burrow": burrow_frames(st),
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


def sleep_frames(st=None):
    """Return (sleepy sheet, sleep sheet, wake sheet) frame lists."""
    st = st or CLASSIC

    def draw_bunny(**kw):  # noqa: F811 - style-bound shorthand
        return _draw_bunny(style=st, **kw)
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


_draw_bunny = draw_bunny


# --------------------------------------------------------------------------
# Idle behaviours
# --------------------------------------------------------------------------

DIRT = (150, 102, 62, 255)
DIRT_DARK = (108, 70, 42, 255)
DIRT_LIGHT = (188, 138, 88, 255)
HOLE = (42, 30, 26, 255)


def specks(c: Canvas, pts):
    for i, (x, y) in enumerate(pts):
        c.set(x, y, DIRT if i % 2 else DIRT_DARK)


def _norm(dx, dy):
    n = math.hypot(dx, dy)
    return dx / n, dy / n


# Carrot geometry: the tip goes to the mouth; bites shorten it from the tip.
MOUTH = (26.4, 17.8)
CARROT_DIR = _norm(0.5, -1.0)          # from leafy top (in the paws) to the tip


def carrot_at_mouth(length):
    bx = MOUTH[0] - CARROT_DIR[0] * (length + 0.6)
    by = MOUTH[1] - CARROT_DIR[1] * (length + 0.6)
    return (bx, by), CARROT_DIR, length


def paws_at(base, spread=1.4):
    bx, by = base
    return (bx + 0.6, by - 0.4, 1.9, 1.6), (bx - spread + 0.4, by + 0.2, 1.9, 1.6)


NOTICE = dict(SIT, head=(21.4, 17.0, 6.4, 5.6), ears=((19.0, 13.0, 10.0, 0.05), (22.0, 12.5, 10.0, -0.15)))
SNIFF_A = dict(body=(14.2, 22.6, 8.2, 5.6), head=(22.6, 20.0, 6.0, 5.2),
               ears=((19.6, 16.2, 9.6, 0.42), (22.4, 15.8, 9.6, 0.28)),
               back_foot=(10.5, 27.8, 3.6, 1.6), front_paw=(21.0, 27.6, 1.9, 1.5), tail=(6.2, 20.5, 2.6))
SNIFF_B = dict(SNIFF_A, head=(22.8, 20.6, 6.0, 5.2))
HOLDING = dict(SIT, body=(13.8, 22.0, 7.8, 6.2), head=(21.0, 15.8, 6.4, 5.6))


def carrot_frames(st):
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    out = [d(NOTICE), d(SNIFF_A), d(SNIFF_B, nose_twitch=True)]
    # Pull: paws at the ground, leaves showing; then the carrot pops out.
    pull1 = d(dict(SNIFF_A, front_paw=(25.2, 27.8, 2.2, 1.3)),
              carrot=((27.2, 27.0), _norm(0.2, 1.0), 1.0))
    out.append(pull1)
    pb = (24.0, 24.2)
    p1, p2 = paws_at(pb)
    out.append(d(dict(HOLDING, head=(21.2, 16.4, 6.4, 5.6)), front_paw=p1, front_paw2=p2,
                 carrot=(pb, CARROT_DIR, 6.0)))
    # Hold, then three bites; each chew shows a shorter carrot.
    hb = (24.2, 23.4)
    p1, p2 = paws_at(hb)
    out.append(d(HOLDING, front_paw=p1, front_paw2=p2, carrot=(hb, CARROT_DIR, 6.0)))
    for length, nxt in ((6.0, 4.0), (4.0, 2.2), (2.2, 0.0)):
        base, dirv, ln = carrot_at_mouth(length)
        p1, p2 = paws_at(base)
        out.append(d(dict(HOLDING, head=(21.4, 16.2, 6.4, 5.6)), mouth="yawn",
                     front_paw=p1, front_paw2=p2, carrot=(base, dirv, ln)))
        p1, p2 = paws_at(hb)
        out.append(d(HOLDING, blush_big=True, front_paw=p1, front_paw2=p2,
                     carrot=(hb, CARROT_DIR, nxt) if nxt > 0 else None))
    out.append(d(HOLDING, eyes="happy", mouth="tongue",
                 front_paw=(22.6, 22.6, 1.9, 1.6), front_paw2=(21.4, 23.0, 1.9, 1.6)))
    return out  # 13: notice, sniffA, sniffB, pull1, pull2, hold, (bite, chew) x3, done


PAWS_UP = dict(SIT, body=(14.0, 21.8, 7.8, 6.2))
SITBACK = dict(body=(13.2, 22.8, 7.8, 6.0), head=(20.6, 16.0, 6.4, 5.6),
               ears=((18.6, 12.2, 10.0, 0.20), (21.6, 11.7, 10.0, 0.04)),
               back_foot=(10.0, 27.8, 3.8, 1.6), front_paw=(19.0, 27.6, 1.9, 1.5), tail=(5.6, 20.6, 2.6))


def groom_frames(st):
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    wash = [
        d(PAWS_UP, front_paw=(24.2, 19.6, 1.8, 1.6), front_paw2=(22.8, 20.2, 1.8, 1.6)),
        d(dict(PAWS_UP, head=(21.0, 16.2, 6.4, 5.6)), eyes="closed",
          front_paw=(24.8, 16.6, 1.8, 1.6), front_paw2=(23.4, 17.4, 1.8, 1.6)),
        d(dict(PAWS_UP, head=(21.2, 15.6, 6.4, 5.6)), eyes="closed",
          front_paw=(25.2, 19.2, 1.8, 1.6), front_paw2=(23.8, 20.0, 1.8, 1.6)),
        d(dict(SIT, ears=((19.0, 12.0, 10.0, 0.48), (22.0, 11.5, 10.0, -0.28)))),
        d(dict(SIT, ears=((19.0, 12.0, 10.0, -0.06), (22.0, 11.5, 10.0, 0.32)))),
        d(lerp_pose(dict(PAWS_UP, front_paw=(24.2, 19.6, 1.8, 1.6)), SIT, 0.6)),
    ]
    scratch = [
        d(SITBACK),
        d(dict(SITBACK, back_foot=(15.6, 17.6, 1.6, 3.4), head=(21.0, 16.6, 6.4, 5.6)), foot_front=True),
        d(dict(SITBACK, back_foot=(17.4, 13.0, 1.6, 3.0), head=(21.2, 16.8, 6.4, 5.6),
                 ears=((18.8, 13.0, 10.0, 0.35), (21.8, 12.5, 10.0, 0.12))), foot_front=True, eyes="happy"),
        d(dict(SITBACK, back_foot=(16.4, 14.8, 1.6, 3.0), head=(21.2, 16.8, 6.4, 5.6),
                 ears=((18.8, 13.0, 10.0, 0.30), (21.8, 12.5, 10.0, 0.04))), foot_front=True, eyes="happy"),
        d(dict(SITBACK, back_foot=(12.6, 24.2, 2.6, 2.2)), foot_front=True),
    ]
    return wash + scratch  # 11: wash x6, scratch x5


def moves_frames(st):
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    deep = dict(STRETCH, front_paw=(27.0, 28.0, 2.8, 1.0))
    stretch = [
        d(lerp_pose(SIT, STRETCH, 0.5)),
        d(deep),
        d(dict(deep, ears=((19.6, 15.6, 10.5, 0.98), (21.6, 15.0, 10.5, 0.84))), eyes="closed", mouth="yawn"),
        d(lerp_pose(STRETCH, SIT, 0.5)),
    ]
    look = [
        d(dict(SIT, head=(20.8, 15.8, 6.2, 5.6)), face=0),
        d(dict(SIT, head=(20.4, 15.8, 6.4, 5.6), ears=((19.4, 12.0, 10.0, 0.05), (22.2, 11.5, 10.0, -0.12))),
          face=-1),
        d(dict(SIT, head=(21.2, 15.2, 6.4, 5.6), ears=((19.0, 11.4, 10.0, 0.30), (22.0, 10.9, 10.0, 0.14))),
          look_up=True),
    ]
    return stretch + look  # 7: stretch x4, look front/back/up


# --------------------------------------------------------------------------
# Burrow
# --------------------------------------------------------------------------

GROUND_ROW = 29   # feet rest on this row in every grounded frame

CURL = dict(body=(16.0, 23.6, 7.4, 5.2), head=(21.4, 20.0, 5.8, 5.0),
            ears=((18.4, 17.0, 10.0, 0.95), (20.4, 16.6, 10.0, 0.85)),
            back_foot=(12.5, 28.0, 3.0, 1.2), front_paw=(22.5, 28.0, 2.0, 1.2), tail=(9.2, 22.0, 2.4))
EARS_UP = dict(SIT, ears=((19.0, 12.0, 10.0, 0.05), (22.0, 11.5, 10.0, -0.08)))
POP = dict(body=(14.5, 21.2, 7.6, 6.4), head=(21.2, 14.6, 6.4, 5.6),
           ears=((19.0, 10.6, 10.4, 0.02), (22.0, 10.1, 10.4, -0.10)),
           back_foot=(11.0, 27.8, 3.4, 1.6), front_paw=(19.5, 27.6, 1.9, 1.5), tail=(6.6, 19.4, 2.6))
DIG = dict(body=(13.0, 23.2, 8.6, 5.2), head=(21.6, 19.6, 6.0, 5.2),
           ears=((18.6, 15.6, 9.6, 0.62), (21.6, 15.2, 9.6, 0.48)),
           back_foot=(9.0, 27.8, 4.0, 1.4), front_paw=(24.6, 28.0, 2.2, 1.2), tail=(4.8, 21.5, 2.6))


def sink(c: Canvas, shift: int, ground=GROUND_ROW) -> Canvas:
    """The bunny lowered by `shift` px into a hole: everything that would be
    below the ground line is cut away (the hole's front rim covers the edge)."""
    out = Canvas(c.w, c.h)
    for y in range(c.h):
        ty = y + shift
        if ty > ground:
            continue
        out.px[ty] = list(c.px[y])
    return out


def burrow_frames(st):
    d = lambda base=None, **kw: draw_bunny(style=st, **{**(base or {}), **kw})
    dig1 = d(DIG)
    specks(dig1, [(3, 24), (5, 22), (2, 21), (4, 26)])
    dig2 = d(dict(DIG, front_paw=(21.0, 27.6, 2.0, 1.4), head=(21.8, 19.2, 6.0, 5.2)))
    specks(dig2, [(4, 20), (1, 18), (6, 17), (2, 23)])
    curl = d(CURL, eyes="closed")
    up = d(EARS_UP)
    # Sink depths from the curled pose's real top row, so the last frame
    # still shows the ear tips (3 rows) above the ground line.
    top = min(y for y in range(FRAME) for x in range(FRAME) if curl.px[y][x][3])
    deepest = GROUND_ROW - top - 3
    depths = [round(deepest * k / 4) for k in (1, 2, 3, 4)]
    shake1 = d(dict(SIT, ears=((19.0, 12.0, 10.0, 0.48), (22.0, 11.5, 10.0, 0.32))), eyes="closed")
    specks(shake1, [(5, 14), (27, 9), (29, 15), (3, 19)])
    shake2 = d(dict(SIT, ears=((19.0, 12.0, 10.0, -0.22), (22.0, 11.5, 10.0, -0.38))), eyes="closed")
    specks(shake2, [(2, 12), (28, 12), (30, 18), (6, 10)])
    return [
        d(SNIFF_A), d(SNIFF_B, nose_twitch=True), dig1, dig2,
        sink(curl, depths[0]), sink(curl, depths[1]), sink(curl, depths[2]), sink(curl, depths[3]),
        sink(up, 20), sink(up, 10), d(POP), shake1, shake2,
    ]  # 13


def burrow_fx_frames():
    """Hole effect frames as (back, front) canvases: back is drawn behind the
    bunny (hole interior, far dirt), front in front of it (near rim)."""
    def frame(hole_rx, pile, rim, scatter=()):
        back, front = Canvas(), Canvas()
        cx, cy = 16.0, GROUND_ROW + 0.4
        for (px_, py_, rx, ry) in pile:
            back.ellipse(px_, py_, rx, ry, DIRT, shade=DIRT_DARK, shade_from=0.2)
        if hole_rx:
            back.ellipse(cx, cy - 0.6, hole_rx + 1, 2.4, DIRT_DARK)
            back.ellipse(cx, cy - 0.4, hole_rx, 1.8, HOLE)
            if rim:
                for x in range(int(cx - hole_rx) - 1, int(cx + hole_rx) + 2):
                    dx = (x + 0.5 - cx) / (hole_rx + 1)
                    if abs(dx) <= 1:
                        yrim = int(round(cy + 1.4 * math.sqrt(max(0, 1 - dx * dx))))
                        front.set(x, min(yrim, 31), DIRT_LIGHT)
                        front.set(x, min(yrim + 1, 31), DIRT)
        for x, y in scatter:
            front.set(x, y, DIRT_DARK)
        return back, front
    return [
        frame(0, [(16, 29.2, 5, 1.8)], False, [(11, 30), (21, 30)]),
        frame(5, [(8, 28.6, 3.2, 1.8), (24, 28.6, 3.2, 1.8)], True),
        frame(11, [(4, 28.6, 3.0, 2.0), (28, 28.6, 3.0, 2.0)], True),
        frame(6, [(10, 29.0, 3.4, 1.6), (22, 29.0, 3.4, 1.6)], True),
        frame(0, [], False, [(8, 30), (11, 31), (14, 30), (17, 31), (19, 30), (22, 31), (24, 30), (16, 30),
                             (12, 29), (20, 29)]),
    ]  # mound1, mound2, hole, close1, close2


# --------------------------------------------------------------------------
# Hover heart
# --------------------------------------------------------------------------

HEART = (255, 110, 156, 255)
HEART_LIGHT = (255, 186, 210, 255)
HEART_EDGE = (196, 58, 104, 255)
HEART_SIZE = 16


def heart_sprite() -> Canvas:
    c = Canvas(HEART_SIZE, HEART_SIZE)
    shape = [
        "..##.##..",
        ".#######.",
        "#########",
        "#########",
        ".#######.",
        "..#####..",
        "...###...",
        "....#....",
    ]
    ox, oy = 3, 4
    for y, row in enumerate(shape):
        for x, ch in enumerate(row):
            if ch == "#":
                c.set(ox + x, oy + y, HEART)
    for x, y in ((ox + 2, oy + 1), (ox + 1, oy + 2), (ox + 2, oy + 2)):
        c.set(x, y, HEART_LIGHT)
    c.outline(HEART_EDGE)
    return c


# Pose name -> (sheet, 1-based frame). MIRRORS Bunny.POSES in Animation.lua;
# the test-suite checks they are identical.
POSES = {
    "idle": ("bunny-idle", 1), "blink": ("bunny-idle", 2), "twitch": ("bunny-idle", 3),
    "breathe": ("bunny-idle", 4),
    "prep": ("bunny-hop", 1), "push": ("bunny-hop", 2), "jump": ("bunny-hop", 3),
    "apex": ("bunny-hop", 4), "fall": ("bunny-hop", 5), "contact": ("bunny-hop", 6),
    "land": ("bunny-hop", 7), "recover": ("bunny-hop", 8),
    "drowsy1": ("bunny-sleepy", 1), "drowsy2": ("bunny-sleepy", 2), "drowsy3": ("bunny-sleepy", 3),
    "liedown1": ("bunny-sleepy", 4), "liedown2": ("bunny-sleepy", 5),
    "liedown3": ("bunny-sleepy", 6), "liedown4": ("bunny-sleepy", 7),
    "sleep1": ("bunny-sleep", 1), "sleep2": ("bunny-sleep", 2), "sleep3": ("bunny-sleep", 3),
    "sleep4": ("bunny-sleep", 4), "sleepEar": ("bunny-sleep", 5), "sleepNose": ("bunny-sleep", 6),
    "wake1": ("bunny-wake", 1), "wake2": ("bunny-wake", 2), "wake3": ("bunny-wake", 3),
    "wake4": ("bunny-wake", 4),
    "carrotNotice": ("bunny-carrot", 1), "carrotSniffA": ("bunny-carrot", 2),
    "carrotSniffB": ("bunny-carrot", 3), "carrotPull": ("bunny-carrot", 4),
    "carrotPop": ("bunny-carrot", 5), "carrotHold": ("bunny-carrot", 6),
    "carrotBite1": ("bunny-carrot", 7), "carrotChew1": ("bunny-carrot", 8),
    "carrotBite2": ("bunny-carrot", 9), "carrotChew2": ("bunny-carrot", 10),
    "carrotBite3": ("bunny-carrot", 11), "carrotChew3": ("bunny-carrot", 12),
    "carrotDone": ("bunny-carrot", 13),
    "washUp": ("bunny-groom", 1), "washRubA": ("bunny-groom", 2), "washRubB": ("bunny-groom", 3),
    "washWiggleA": ("bunny-groom", 4), "washWiggleB": ("bunny-groom", 5), "washDown": ("bunny-groom", 6),
    "scratchSit": ("bunny-groom", 7), "scratchFootUp": ("bunny-groom", 8),
    "scratchA": ("bunny-groom", 9), "scratchB": ("bunny-groom", 10), "scratchFootDown": ("bunny-groom", 11),
    "stretchReach": ("bunny-moves", 1), "stretchDeep": ("bunny-moves", 2),
    "stretchHold": ("bunny-moves", 3), "stretchBack": ("bunny-moves", 4),
    "lookFront": ("bunny-moves", 5), "lookBack": ("bunny-moves", 6), "lookUp": ("bunny-moves", 7),
    "burrowSniffA": ("bunny-burrow", 1), "burrowSniffB": ("bunny-burrow", 2),
    "burrowDigA": ("bunny-burrow", 3), "burrowDigB": ("bunny-burrow", 4),
    "burrowSink1": ("bunny-burrow", 5), "burrowSink2": ("bunny-burrow", 6),
    "burrowSink3": ("bunny-burrow", 7), "burrowSink4": ("bunny-burrow", 8),
    "burrowEmerge1": ("bunny-burrow", 9), "burrowEmerge2": ("bunny-burrow", 10),
    "burrowPop": ("bunny-burrow", 11), "burrowShakeA": ("bunny-burrow", 12),
    "burrowShakeB": ("bunny-burrow", 13),
}

# Sequences: (pose, seconds). MIRRORS Bunny.SEQUENCES in Animation.lua.
SEQUENCES = {
    "drowsy": [("drowsy1", 0.24), ("drowsy2", 0.28), ("drowsy3", 0.22)],
    "liedown": [("liedown1", 0.15), ("liedown2", 0.15), ("liedown3", 0.16), ("liedown4", 0.18)],
    "breathe": [("sleep1", 0.65), ("sleep2", 0.55), ("sleep3", 0.65), ("sleep4", 0.55)],
    "wake": [("wake1", 0.22), ("wake2", 0.20), ("wake3", 0.26), ("wake4", 0.20)],
    "rise": [("liedown4", 0.10), ("liedown3", 0.10), ("liedown2", 0.10), ("liedown1", 0.10)],
    "carrot": [("carrotNotice", 0.30), ("carrotSniffA", 0.20), ("carrotSniffB", 0.20),
               ("carrotSniffA", 0.20), ("carrotSniffB", 0.20), ("carrotPull", 0.35),
               ("carrotPop", 0.30), ("carrotHold", 0.35), ("carrotBite1", 0.18),
               ("carrotChew1", 0.30), ("carrotBite2", 0.18), ("carrotChew2", 0.30),
               ("carrotBite3", 0.18), ("carrotChew3", 0.35), ("carrotDone", 0.45)],
    "wash": [("washUp", 0.25), ("washRubA", 0.15), ("washRubB", 0.15), ("washRubA", 0.15),
             ("washRubB", 0.15), ("washRubA", 0.15), ("washWiggleA", 0.14), ("washWiggleB", 0.14),
             ("washWiggleA", 0.14), ("washWiggleB", 0.14), ("washDown", 0.20)],
    "scratch": [("scratchSit", 0.25), ("scratchFootUp", 0.15)]
               + [("scratchA", 0.08), ("scratchB", 0.08)] * 5
               + [("scratchFootDown", 0.15), ("scratchSit", 0.15)],
    "stretch": [("stretchReach", 0.25), ("stretchDeep", 0.30), ("stretchHold", 0.50),
                ("stretchReach", 0.25), ("stretchBack", 0.20)],
    "look": [("lookFront", 0.20), ("lookBack", 0.70), ("lookFront", 0.20), ("lookUp", 0.50)],
    "burrowSniff": [("burrowSniffA", 0.30), ("burrowSniffB", 0.30), ("burrowSniffA", 0.25),
                    ("burrowSniffB", 0.30)],
    "burrowDig": [("burrowDigA", 0.15), ("burrowDigB", 0.15)] * 4,
    "burrowSink": [("burrowSink1", 0.12), ("burrowSink2", 0.12), ("burrowSink3", 0.12),
                   ("burrowSink4", 0.12)],
    "burrowEmerge": [("burrowEmerge1", 0.20), ("burrowEmerge2", 0.20), ("burrowPop", 0.20)],
    "burrowShake": [("burrowShakeA", 0.12), ("burrowShakeB", 0.12), ("burrowShakeA", 0.12),
                    ("burrowShakeB", 0.12), ("idle", 0.20)],
}
TIMINGS = {name: [t for _, t in steps] for name, steps in SEQUENCES.items()}

# Hole effect changes at sequence steps: step -> (holes, fx frame or None).
# MIRRORS Bunny.BURROW_FX in Animation.lua. Frames: 1 mound, 2 bigger mound
# with a small hole, 3 open hole, 4 closing, 5 last specks; None hides.
BURROW_FX = {
    "burrowDig": {1: ("A", 1), 4: ("A", 2), 7: ("A", 3)},
    "burrowEmerge": {1: ("B", 3)},
    "burrowShake": {3: ("AB", 4), 4: ("AB", 5), 5: ("AB", None)},
}


# Hop ground phases (seconds at speed 1.0) and air poses by hop progress.
HOP_TIMING = {"prep": 0.09, "push": 0.05, "contact": 0.04, "land": 0.07, "recover": 0.06}
AIR_POSES = [(0.38, "jump"), (0.64, "apex"), (1.01, "fall")]

# Burrow: seconds underground before the second hole opens, then before the
# bunny peeks out. Hearts: particle parameters (sizes relative to the bunny).
BURROW_UNDERGROUND = 0.6
BURROW_HOLE_OPEN = 0.25
HEART_PARTICLE = {"duration": 1.4, "rise": 0.55, "drift": 0.15, "size": 0.28, "fadeDelay": 0.5}

# Texture slot count per sheet (power of two >= frame count).
def slots_for(count):
    n = 1
    while n < count:
        n *= 2
    return n


# --------------------------------------------------------------------------
# Encoders
# --------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Fur / detail layers
# ---------------------------------------------------------------------------

FUR_BASE = FUR                  # tint that reproduces the original art
DEFAULT_FUR_HEX = "%02X%02X%02X" % FUR_BASE[:3]
# Fur tones are tinted in game. SHADE_DARK (mouth) and LID (drowsy eyelid)
# are darker fur tones, so they darken with the fur instead of showing as a
# fixed lavender pixel on coloured bunnies. PATCH / SCALE: style fur tones.
FUR_RGB = {FUR[:3], SHADE[:3], TAIL[:3], SHADE_DARK[:3], LID[:3], PATCH[:3], SCALE[:3]}


def is_fur(p) -> bool:
    return p[3] > 0 and p[:3] in FUR_RGB


def split_layers(c: Canvas):
    """(fur, detail) canvases. Fur is normalised by FUR_BASE so that tinting
    with colour X gives the main fur exactly X."""
    fur, detail = Canvas(c.w, c.h), Canvas(c.w, c.h)
    for y in range(c.h):
        for x in range(c.w):
            p = c.px[y][x]
            if p[3] == 0:
                continue
            if is_fur(p):
                fur.px[y][x] = tuple(min(255, round(p[i] * 255 / FUR_BASE[i])) for i in range(3)) + (p[3],)
            else:
                detail.px[y][x] = p
    return fur, detail


def tint_composite(c: Canvas, hex_color: str) -> Canvas:
    """What the addon draws: fur layer x tint, detail layer on top."""
    tint = tuple(int(hex_color[i:i + 2], 16) for i in (0, 2, 4))
    fur, detail = split_layers(c)
    out = Canvas(c.w, c.h)
    for y in range(c.h):
        for x in range(c.w):
            f, d = fur.px[y][x], detail.px[y][x]
            if d[3]:
                out.px[y][x] = d
            elif f[3]:
                out.px[y][x] = tuple(round(f[i] * tint[i] / 255) for i in range(3)) + (f[3],)
    return out


def strip(canvases, frame_h=FRAME):
    """Horizontal strip of frames, padded with transparent slots to a
    power-of-two width; returns (w, h, rows) for ONE layer."""
    slots = slots_for(len(canvases))
    w = FRAME * slots
    rows = []
    for y in range(frame_h):
        row = []
        for c in canvases:
            row.extend(c.px[y])
        row.extend([CLEAR] * (FRAME * (slots - len(canvases))))
        rows.append(row)
    return w, frame_h, rows


def layered_strip(canvases, frame_h=FRAME):
    """Fur layer strip on top, detail layer strip below (height 2*frame_h)."""
    furs, details = zip(*(split_layers(c) for c in canvases))
    w, _, fur_rows = strip(list(furs), frame_h)
    _, _, detail_rows = strip(list(details), frame_h)
    return w, 2 * frame_h, fur_rows + detail_rows


# ---------------------------------------------------------------------------
# Portrait ears
# ---------------------------------------------------------------------------

EARS_H = 16


def portrait_ears() -> Canvas:
    """A pair of upright bunny ears (32x16), rooted on the bottom edge so they
    can sit on top of a round portrait. Same palette and outline style."""
    c = Canvas(FRAME, EARS_H)
    # (root x, root y, length, tilt): roots just below the bottom edge so the
    # ears look attached to whatever they sit on.
    specs = [(11.0, 17.5, 15.0, 0.24), (21.0, 17.5, 15.0, -0.24)]

    def oval(cx, cy, rx, ry, angle, colour):
        c.ellipse(cx, cy, rx, ry, colour, angle=-angle)

    for bx, by, length, a in specs:
        cx, cy = bx - math.sin(a) * length * 0.5, by - math.cos(a) * length * 0.5
        oval(cx, cy, 4.1, length * 0.5 + 1.0, a, OUTLINE)
    for bx, by, length, a in specs:
        cx, cy = bx - math.sin(a) * length * 0.5, by - math.cos(a) * length * 0.5
        oval(cx, cy, 3.1, length * 0.5, a, FUR)
        icx, icy = bx - math.sin(a) * length * 0.45, by - math.cos(a) * length * 0.45
        oval(icx, icy, 1.4, length * 0.33, a, PINK)
    # Shade the outer edge of each ear slightly for depth.
    for y in range(EARS_H):
        for x in range(FRAME):
            if c.px[y][x] == FUR and (x < 9 or x > 23):
                c.px[y][x] = SHADE
    c.outline()
    return c


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
    for y in range(c.h):
        for x in range(c.w):
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
        sheets["bunny-idle"] + sheets["bunny-hop"][:4],  # awake & hopping (see hop preview)
        sleepy[:3] + sleepy[3:],   # getting sleepy (3) | lying down (4)
        sleep,                     # breathing (4) | ear twitch | nose twitch
        wake,                      # waking up (4)
        colour_variants(sheets),   # fur colours + portrait ears, as rendered in game
    ]


# Fur colours shown in the preview (default first).
PREVIEW_COLOURS = [DEFAULT_FUR_HEX, "FFB6C1", "87CEEB", "A0522D", "3A3A40"]


def colour_variants(sheets):
    idle = sheets["bunny-idle"][0]
    out = [tint_composite(idle, hx) for hx in PREVIEW_COLOURS]
    for hx in (DEFAULT_FUR_HEX, "FFB6C1"):
        ears = tint_composite(portrait_ears(), hx)
        cell = Canvas()  # centre the 32x16 ears in a 32x32 cell
        for y in range(ears.h):
            cell.px[y + 8] = list(ears.px[y])
        out.append(cell)
    return out


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


# --------------------------------------------------------------------------
# v0.3 previews: styles, per-style sheets, animated hop / carrot / burrow /
# hearts. All use the real sprites and the sequences/timings above.
# --------------------------------------------------------------------------

def mirror(c: Canvas) -> Canvas:
    out = Canvas(c.w, c.h)
    for y in range(c.h):
        out.px[y] = list(reversed(c.px[y]))
    return out


def grid_png(groups, scale, pad=4, label_colours=None) -> bytes:
    cell = FRAME * scale
    gap = pad * scale // 2
    cols = max(len(g) for g in groups)
    w = cols * cell + (cols + 1) * gap
    h = len(groups) * cell + (len(groups) + 1) * gap
    rows = [[BG_LIGHT if ((x // 16) + (y // 16)) % 2 == 0 else BG_DARK for x in range(w)]
            for y in range(h)]
    for gi, group in enumerate(groups):
        for i, c in enumerate(group):
            blit(rows, c, gap + i * (cell + gap), gap + gi * (cell + gap), scale)
    return encode_png(w, h, rows)


def style_sheet_rows(sheets, hex_color):
    t = lambda cs: [tint_composite(c, hex_color) for c in cs]
    groom, moves, carrot, burrow = sheets["bunny-groom"], sheets["bunny-moves"], sheets["bunny-carrot"], sheets["bunny-burrow"]
    return [
        t(sheets["bunny-idle"] + sheets["bunny-hop"][:4]),
        t(sheets["bunny-hop"][4:] + sheets["bunny-wake"]),
        t(sheets["bunny-sleepy"]),
        t(sheets["bunny-sleep"]),
        t(carrot[:7]),
        t(carrot[7:]),
        t(groom[:6]),
        t(groom[6:] + moves[:3]),
        t(moves[3:] + burrow[:4]),
        t(burrow[4:]),
    ]


class Scene:
    """A strip of 'track' for animated previews, in source pixels."""

    def __init__(self, w, h, scale):
        self.w, self.h, self.scale = w, h, scale
        self.ground = h - 3  # row under the feet

    def render(self, items):
        s = self.scale
        rows = [[BG_LIGHT] * (self.w * s) for _ in range(self.h * s)]
        for x in range(self.w * s):
            rows[(self.ground + 1) * s][x] = GROUND
        for c, x, y in items:
            # Bunny frames rest on GROUND_ROW; smaller sprites (hearts) on their bottom row.
            foot = GROUND_ROW if c.h == FRAME else c.h - 1
            top = self.ground - foot - int(round(y))
            blit_clip(rows, c, int(round(x)) * s, top * s, s)
        return rows


def blit_clip(rows, c, x0, y0, scale):
    H, W = len(rows), len(rows[0])
    for y in range(c.h):
        for x in range(c.w):
            p = c.px[y][x]
            if p[3] == 0:
                continue
            for sy in range(scale):
                yy = y0 + y * scale + sy
                if not 0 <= yy < H:
                    continue
                r = rows[yy]
                for sx in range(scale):
                    xx = x0 + x * scale + sx
                    if 0 <= xx < W:
                        r[xx] = blend(r[xx], p)


def seq_frames(sheets, name, hex_color, facing=1):
    out = []
    for pose, t in SEQUENCES[name]:
        sheet, idx = POSES[pose]
        c = tint_composite(sheets[sheet][idx - 1], hex_color)
        out.append((mirror(c) if facing < 0 else c, t))
    return out


def hop_gif(sheets, hex_color=DEFAULT_FUR_HEX, scale=2) -> bytes:
    # Default settings: size 64 = 2 UI units per source pixel, so a hop of
    # max(8, 1.5 * 64) = 96 units is 48 px, hop height 16 units = 8 px.
    step, height, air, fps = 48, 8, 0.4, 25
    scene = Scene(32 + 2 * step + 8, 32 + height + 6, scale)
    pose = lambda name: tint_composite(sheets[POSES[name][0]][POSES[name][1] - 1], hex_color)
    frames_out = []
    x = 4

    def add(c, x_, y_, t, facing):
        frames_out.append((scene.render([(mirror(c) if facing < 0 else c, x_, y_)]), t))

    for facing in (1, -1):
        add(pose("idle"), x, 0, 0.7, facing)
        for hop_i in range(2):
            add(pose("prep"), x, 0, HOP_TIMING["prep"], facing)
            add(pose("push"), x, 0, HOP_TIMING["push"], facing)
            n = int(air * fps)
            for k in range(n):
                t = (k + 0.5) / n
                name = next(nm for lim, nm in AIR_POSES if t < lim)
                add(pose(name), x + facing * step * t, 4 * height * t * (1 - t), 1 / fps, facing)
            x += facing * step
            add(pose("contact"), x, 0, HOP_TIMING["contact"], facing)
            add(pose("land"), x, 0, HOP_TIMING["land"], facing)
        add(pose("recover"), x, 0, HOP_TIMING["recover"], facing)
    add(pose("idle"), x, 0, 0.5, 1)
    return encode_gif(frames_out, scene.w * scale, scene.h * scale)


def carrot_gif(sheets, hex_color=DEFAULT_FUR_HEX, scale=4) -> bytes:
    scene = Scene(40, 36, scale)
    idle = tint_composite(sheets["bunny-idle"][0], hex_color)
    seq = [(idle, 0.6)] + seq_frames(sheets, "carrot", hex_color) + [(idle, 0.8)]
    return encode_gif([(scene.render([(c, 4, 0)]), t) for c, t in seq], scene.w * scale, scene.h * scale)


def burrow_gif(sheets, hex_color=DEFAULT_FUR_HEX, scale=3) -> bytes:
    fx = burrow_fx_frames()
    scene = Scene(32 * 4 + 8, 38, scale)
    ax, bx = 4, 4 + 32 * 3
    holes = {"A": None, "B": None}
    out = []
    idle = tint_composite(sheets["bunny-idle"][0], hex_color)

    def frame(c, x, t):
        items = []
        for key, hx in (("A", ax), ("B", bx)):
            if holes[key]:
                items.append((fx[holes[key] - 1][0], hx, 0))
        if c is not None:
            items.append((c, x, 0))
        for key, hx in (("A", ax), ("B", bx)):
            if holes[key]:
                items.append((fx[holes[key] - 1][1], hx, 0))
        out.append((scene.render(items), t))

    def play(name, x):
        steps = BURROW_FX.get(name, {})
        for i, (c, t) in enumerate(seq_frames(sheets, name, hex_color), start=1):
            if i in steps:
                which, fr = steps[i]
                for key in which:
                    holes[key] = fr
            frame(c, x, t)

    frame(idle, ax, 0.7)
    play("burrowSniff", ax)
    play("burrowDig", ax)
    play("burrowSink", ax)
    frame(None, ax, BURROW_UNDERGROUND)
    holes["B"] = 1
    frame(None, bx, BURROW_HOLE_OPEN)
    play("burrowEmerge", bx)
    play("burrowShake", bx)
    frame(idle, bx, 0.8)
    return encode_gif(out, scene.w * scale, scene.h * scale)


def hearts_gif(sheets, hex_color=DEFAULT_FUR_HEX, scale=4) -> bytes:
    """Hearts rising over a SLEEPING bunny (hovering never wakes it)."""
    import random
    rng = random.Random(7)
    P = HEART_PARTICLE
    size_px = 32                      # bunny drawn at its 32-pixel source size
    heart = heart_sprite()
    hs = max(6, int(size_px * P["size"]))
    small = Canvas(hs, hs)            # nearest-neighbour downscale of the heart
    for y in range(hs):
        for x in range(hs):
            small.px[y][x] = heart.px[y * HEART_SIZE // hs][x * HEART_SIZE // hs]
    scene = Scene(48, 56, scale)
    breathe = seq_frames(sheets, "breathe", hex_color)
    loop, fps = sum(t for _, t in breathe), 12
    interval = 0.35                   # "normal" intensity
    hearts = []
    t, emit_t = 0.0, 0.0
    out = []
    while t < loop * 2 - 1e-6:
        while emit_t <= t:
            hearts.append((emit_t, 14 + rng.uniform(-3, 3), rng.uniform(-1, 1) * P["drift"] * size_px))
            emit_t += interval
        # current breathing frame
        acc, c = 0.0, breathe[0][0]
        for cc, dt in breathe:
            if (t % loop) >= acc:
                c = cc
            acc += dt
        items = [(c, 6, 0)]
        for t0, hx, dx in hearts:
            age = t - t0
            if 0 <= age < P["duration"]:
                k = age / P["duration"]
                a = 1.0 if age < P["fadeDelay"] else max(0.0, 1 - (age - P["fadeDelay"]) / (P["duration"] - P["fadeDelay"]))
                faded = Canvas(hs, hs)
                for y in range(hs):
                    for x in range(hs):
                        p = small.px[y][x]
                        faded.px[y][x] = p[:3] + (int(p[3] * a),)
                rise = P["rise"] * size_px * k
                items.append((faded, hx + dx * k, 13 + rise))   # from the sleeping head
        out.append((scene.render(items), 1 / fps))
        t += 1 / fps
    return encode_gif(out, scene.w * scale, scene.h * scale)


def previews_v3(all_sheets):
    outs = {}
    overview = []
    for st in STYLES:
        sh = all_sheets[st.id]
        picks = [sh["bunny-idle"][0], sh["bunny-hop"][3], sh["bunny-sleep"][0], sh["bunny-carrot"][5],
                 sh["bunny-moves"][4], sh["bunny-groom"][8], sh["bunny-burrow"][10]]
        overview.append([tint_composite(c, st.default_fur) for c in picks])
        outs[IMAGES / f"sprites-{st.id}.png"] = grid_png(style_sheet_rows(sh, st.default_fur), 3)
    outs[IMAGES / "styles.png"] = grid_png(overview, 4)
    classic = all_sheets["classic"]
    outs[IMAGES / "hop-preview.gif"] = hop_gif(classic)
    outs[IMAGES / "carrot-preview.gif"] = carrot_gif(classic)
    outs[IMAGES / "burrow-preview.gif"] = burrow_gif(classic)
    outs[IMAGES / "hearts-preview.gif"] = hearts_gif(classic)
    return outs


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


SPRITE_DATA_PATH = ROOT / "addon" / "BunnyBar" / "SpriteData.lua"
IMAGES = ROOT / "docs" / "images"


def style_dir(style_id):
    """Classic keeps the original folder; other styles get a subfolder."""
    return TEXTURE_DIR if style_id == "classic" else TEXTURE_DIR / style_id


def bbox(c: Canvas, ignore=(ZZZ[:3], DIRT[:3], DIRT_DARK[:3])):
    """Tight box (x0, y0, x1, y1), top-left origin, x1/y1 exclusive, of the
    visible bunny (floating z's and dirt specks don't count for hovering)."""
    xs, ys = [], []
    for y in range(c.h):
        for x in range(c.w):
            p = c.px[y][x]
            if p[3] and p[:3] not in ignore:
                xs.append(x)
                ys.append(y)
    if not xs:
        return (0, 0, 0, 0)
    return (min(xs), min(ys), max(xs) + 1, max(ys) + 1)


def sprite_data_lua(all_sheets) -> bytes:
    lines = [
        "-- BunnyBar: per-frame sprite bounds for hover hit-testing.",
        "-- GENERATED by scripts/generate_sprites.py - do not edit by hand.",
        "-- [style][sheet file][frame] = { x0, y0, x1, y1 } in source pixels",
        "-- (32x32 frame, top-left origin, x1/y1 exclusive).",
        "",
        "local _, ns = ...",
        "",
        "ns.SpriteData = {",
    ]
    for st in STYLES:
        lines.append(f"    {st.id} = {{")
        for name, canvases in all_sheets[st.id].items():
            boxes = ", ".join("{ %d, %d, %d, %d }" % bbox(c) for c in canvases)
            lines.append(f'        ["{name}.tga"] = {{ {boxes} }},')
        lines.append("    },")
    lines.append("}")
    return ("\n".join(lines) + "\n").encode()


def fx_strip(pairs):
    """Burrow effect sheet: back layer strip on top, front layer below."""
    backs, fronts = zip(*pairs)
    w, _, back_rows = strip(list(backs))
    _, _, front_rows = strip(list(fronts))
    return w, 2 * FRAME, back_rows + front_rows


def build():
    all_sheets = {st.id: frames(st) for st in STYLES}
    sheets = all_sheets["classic"]
    outputs = {}
    for st in STYLES:
        for name, canvases in all_sheets[st.id].items():
            w, h, rows = layered_strip(canvases)
            outputs[style_dir(st.id) / f"{name}.tga"] = encode_tga(w, h, rows)
    w, h, rows = layered_strip([portrait_ears()], EARS_H)
    outputs[TEXTURE_DIR / "bunny-ears.tga"] = encode_tga(w, h, rows)
    w, h, rows = fx_strip(burrow_fx_frames())
    outputs[TEXTURE_DIR / "bunny-burrow-fx.tga"] = encode_tga(w, h, rows)
    w, h, rows = strip([heart_sprite()], HEART_SIZE)
    outputs[TEXTURE_DIR / "bunny-heart.tga"] = encode_tga(HEART_SIZE, h, [r[:HEART_SIZE] for r in rows])
    # The TOC IconTexture shows a whole file, so it gets a plain composite.
    w, h, rows = strip([sheets["bunny-idle"][0]])
    outputs[TEXTURE_DIR / "bunny-icon.tga"] = encode_tga(w, h, rows)
    outputs[SPRITE_DATA_PATH] = sprite_data_lua(all_sheets)
    outputs[PREVIEW_PATH] = preview(sheets)
    outputs[GIF_PATH] = nap_gif(sheets)
    outputs.update(previews_v3(all_sheets))
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
